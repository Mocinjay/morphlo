import AVFoundation
import Speech

/// On-device speech-to-text for a video's audio track. Nothing leaves the Mac.
enum Transcriber {
    private final class Once<T>: @unchecked Sendable { // guarded by `lock`
        private let lock = NSLock()
        private var done = false
        private let resume: (T) -> Void
        init(_ resume: @escaping (T) -> Void) { self.resume = resume }
        func callAsFunction(_ value: T) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { resume(value) }
        }
    }

    /// False in command-line mode: a terminal-launched process that asks for speech permission
    /// gets killed by TCC.
    nonisolated(unsafe) static var mayPrompt = true

    static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined where mayPrompt:
            return await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    static func transcribe(asset: AVURLAsset, sourceName: String, duration: Double, outDir: URL) async -> URL? {
        guard Settings.transcribe else { return nil }
        guard let audio = try? await asset.loadTracks(withMediaType: .audio), !audio.isEmpty else { return nil }
        guard await authorize() else {
            Log.write("Transcription skipped: speech recognition not authorized")
            return nil
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            Log.write("Transcription skipped: recognizer unavailable")
            return nil
        }

        // Export the audio to m4a; the recognizer is most reliable with a plain audio file.
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("morphlo-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        export.outputURL = audioURL
        export.outputFileType = .m4a
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        guard export.status == .completed else {
            Log.write("Transcription skipped: audio export failed \(export.error?.localizedDescription ?? "")")
            return nil
        }

        guard recognizer.supportsOnDeviceRecognition else {
            Log.write("Transcription skipped: on-device recognition not available for \(recognizer.locale.identifier)")
            return nil
        }
        recognizer.queue = OperationQueue() // never depend on the main queue being free
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = true

        var task: SFSpeechRecognitionTask?
        let result: SFSpeechRecognitionResult? = await withCheckedContinuation { c in
            let finish = Once<SFSpeechRecognitionResult?> { c.resume(returning: $0) }
            // Generous ceiling: on-device recognition runs well faster than real time.
            DispatchQueue.global().asyncAfter(deadline: .now() + max(120, duration * 2)) {
                Log.write("Transcription timed out")
                finish(nil)
            }
            task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal { finish(result) }
                else if let error {
                    Log.write("Transcription error: \(error.localizedDescription)")
                    finish(nil)
                }
            }
        }
        task?.cancel()
        guard let result, !result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var lines: [String] = []
        var current: [String] = []
        var lineStart = 0.0
        var lastEnd = 0.0
        for seg in result.bestTranscription.segments {
            if current.isEmpty { lineStart = seg.timestamp }
            else if seg.timestamp - lastEnd > 1.2 || current.count >= 16 {
                lines.append("[\(formatTime(lineStart))] " + current.joined(separator: " "))
                current = []
                lineStart = seg.timestamp
            }
            current.append(seg.substring)
            lastEnd = seg.timestamp + seg.duration
        }
        if !current.isEmpty { lines.append("[\(formatTime(lineStart))] " + current.joined(separator: " ")) }

        let text = "Transcript of \(sourceName) (\(formatTime(duration))), transcribed on-device by Morphlo.\n\n"
            + lines.joined(separator: "\n") + "\n"
        let out = WorkDir.unique(in: outDir, base: "\((sourceName as NSString).deletingPathExtension) transcript", ext: "txt")
        do {
            try text.write(to: out, atomically: true, encoding: .utf8)
            return out
        } catch {
            return nil
        }
    }
}
