import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Audio and video conversion using only what ships with macOS (AVFoundation, ImageIO and the
/// built-in `afconvert`), so Morphlo needs no ffmpeg or other outside tools.
enum NativeAV {
    /// Audio containers Core Audio's `afconvert` can read directly.
    private static let afconvertReadable: Set<String> = ["wav", "aif", "aiff", "aifc", "caf", "m4a", "mp3", "flac", "aac", "mp4"]

    static func convert(_ input: URL, to t: Target, runner: Runner,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        // Local-only: forbid reference movies that point at other (e.g. remote) media.
        let asset = AVURLAsset(url: input, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        let unreadable = FormatError("macOS can't read .\(input.pathExtension.lowercased()) files")
        let hasVideo: Bool, hasAudio: Bool
        do {
            guard try await asset.load(.isReadable) else { throw unreadable }
            hasVideo = !(try await asset.loadTracks(withMediaType: .video)).isEmpty
            hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        } catch {
            throw unreadable
        }
        if t.group == .video, !hasVideo { throw FormatError("This file has no video track") }
        if t.group == .audio, !hasAudio { throw FormatError("This file has no audio track") }

        let out = try uniqueOutput(for: input, ext: t.ext)
        do {
            switch t.id {
            case "mp4-h264": try await export(asset, preset: AVAssetExportPresetHighestQuality, type: .mp4, to: out, runner, progress)
            case "mp4-hevc": try await export(asset, preset: AVAssetExportPresetHEVCHighestQuality, type: .mp4, to: out, runner, progress)
            case "mov-prores": try await export(asset, preset: AVAssetExportPresetAppleProRes422LPCM, type: .mov, to: out, runner, progress)
            case "gif": try await makeGIF(asset, to: out, runner, progress)
            case "m4a" where hasVideo || !afconvertReadable.contains(input.pathExtension.lowercased()):
                try await export(asset, preset: AVAssetExportPresetAppleM4A, type: .m4a, to: out, runner, progress)
            default:
                try await audio(input, asset: asset, hasVideo: hasVideo, target: t, to: out, runner, progress)
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        progress(1)
        return [out]
    }

    // MARK: Video

    private static func export(_ asset: AVAsset, preset: String, type: AVFileType, to out: URL,
                               _ runner: Runner, _ progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw FormatError("This Mac can't export that format")
        }
        guard session.supportedFileTypes.contains(type) else { throw FormatError("This Mac can't write that format") }
        try? FileManager.default.removeItem(at: out)
        session.outputURL = out
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true

        let box = SessionBox(session)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await withCheckedContinuation { c in box.session.exportAsynchronously { c.resume() } } }
            group.addTask {
                while box.session.status == .waiting || box.session.status == .exporting || box.session.status == .unknown {
                    if runner.isCancelled { box.session.cancelExport() }
                    progress(Double(box.session.progress))
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
        switch session.status {
        case .completed: return
        case .cancelled: throw StoppedError()
        default: throw FormatError(session.error?.localizedDescription ?? "Export failed")
        }
    }

    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ s: AVAssetExportSession) { session = s }
    }

    /// Animated GIF from the video's frames (480px wide, up to 15 fps, at most 900 frames).
    private static func makeGIF(_ asset: AVAsset, to out: URL, _ runner: Runner,
                                _ progress: @escaping @Sendable (Double) -> Void) async throws {
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw FormatError("Couldn't read the video's length") }
        let fps = min(15, 900 / duration)
        let count = max(1, Int(duration * fps))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480 * 4)
        let tol = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tol
        generator.requestedTimeToleranceAfter = tol

        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw FormatError("Couldn't create the GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<count {
            try runner.checkCancelled()
            let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: t) { CGImageDestinationAddImage(dest, image, frameProps) }
            progress(Double(i + 1) / Double(count) * 0.95)
        }
        guard CGImageDestinationFinalize(dest) else { throw FormatError("Couldn't write the GIF") }
    }

    // MARK: Audio

    /// Decodes the asset's audio to 24-bit PCM in a CAF file (lossless, any length).
    private static func extractPCM(_ asset: AVAsset, to out: URL, _ runner: Runner,
                                   _ progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw FormatError("This file has no audio track") }
        let duration = try await asset.load(.duration).seconds
        // Keep the source's sample rate and channel count.
        var rate = 48_000.0, channels = 2
        if let desc = try await track.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            if asbd.mSampleRate > 0 { rate = asbd.mSampleRate }
            if asbd.mChannelsPerFrame > 0 { channels = Int(asbd.mChannelsPerFrame) }
        }
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: out, fileType: .caf)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm)
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw FormatError(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "Couldn't read the audio")
        }
        writer.startSession(atSourceTime: .zero)
        while let buffer = output.copyNextSampleBuffer() {
            if runner.isCancelled { reader.cancelReading(); writer.cancelWriting(); throw StoppedError() }
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard input.append(buffer) else { throw FormatError(writer.error?.localizedDescription ?? "Couldn't write the audio") }
            if duration > 0 { progress(min(1, CMSampleBufferGetPresentationTimeStamp(buffer).seconds / duration)) }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if reader.status == .failed || writer.status != .completed {
            throw FormatError(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "Couldn't decode the audio")
        }
    }

    /// Core Audio encodes WAV, AIFF, FLAC, ALAC, AAC and HE-AAC natively via `afconvert`.
    private static func audio(_ input: URL, asset: AVAsset, hasVideo: Bool, target t: Target, to out: URL,
                              _ runner: Runner, _ progress: @escaping @Sendable (Double) -> Void) async throws {
        var source = input
        var temp: URL?
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
        // Video files (and audio afconvert can't open) first get their sound decoded to plain PCM,
        // so lossless targets stay lossless.
        if hasVideo || !afconvertReadable.contains(input.pathExtension.lowercased()) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("morphlo-\(UUID().uuidString).caf")
            temp = tmp
            try await extractPCM(asset, to: tmp, runner) { progress($0 * 0.6) }
            source = tmp
        }
        let args: [String]
        switch t.id {
        case "wav": args = ["-f", "WAVE", "-d", "LEI24"]
        case "aiff": args = ["-f", "AIFF", "-d", "BEI24"]
        case "flac": args = ["-f", "flac", "-d", "flac"]
        case "alac": args = ["-f", "m4af", "-d", "alac"]
        case "he-aac": args = ["-f", "m4af", "-d", "aach"] // let Core Audio pick a valid bitrate for the source
        case "m4a": args = ["-f", "m4af", "-d", "aac", "-s", "3", "-q", "127"] // VBR, highest quality; valid for any source
        default: throw FormatError("\(t.label) isn't available")
        }
        try? FileManager.default.removeItem(at: out)
        try await runner.run("/usr/bin/afconvert", args + [source.path, out.path], duration: 0) { _ in }
    }
}
