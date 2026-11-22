// Adapted from Convert by eliasdesena — https://github.com/newtonstudios/convert (commit fd49eaf)
// Copyright (c) 2026 eliasdesena. MIT License — see THIRD_PARTY_NOTICES.md.

import Foundation

enum FormatConverter {
    /// Converts one file and returns what was written (files, or a folder for multi-page PDFs).
    /// Stopped (`runner.cancel()`) or failed conversions throw and leave nothing half-written behind.
    static func convert(
        _ input: URL, to t: Target, settings s: ConvSettings, runner: Runner,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [URL] {
        // A file whose contents don't match its name gets told so, instead of a vague decode error.
        if let kind = MediaKind.of(input) { try Sniff.verify(input, as: kind) }
        switch t.group {
        case .audio, .video:
            // Morphlo: native AVFoundation / Core Audio instead of ffmpeg (no outside tools).
            return try await NativeAV.convert(input, to: t, runner: runner, progress: progress)

        case .image:
            return [try await Task.detached { try ImageConv.convert(input, t, s, runner: runner) }.value]

        case .document:
            if t.id == "pdf-doc" {
                let out = try uniqueOutput(for: input, ext: "pdf")
                try await DocConv.toPDF(input, out, a4: s.paperA4, runner: runner)
                return [out]
            }
            return [try await Task.detached { try DocConv.textutil(input, t, runner: runner) }.value]

        case .pdfPages:
            return try await Task.detached {
                try PDFConv.convert(input, t, s, runner: runner, progress: progress)
            }.value

        case .font:
            return try await FontConv.convert(input, t, runner: runner)
        }
    }

    /// Formats with a hardware encoder use it by default, but not every Mac has every one (ProRes,
    /// HEVC on older Intel Macs, virtual machines), and ffmpeg then fails. Rather than fail the
    /// conversion, it's tried once more with the software encoder: slower, but it works anywhere.
    static func withSoftwareFallback(
        _ t: Target, _ s: ConvSettings, runner: Runner,
        _ encode: (ConvSettings) async throws -> Void
    ) async throws {
        do {
            try await encode(s)
        } catch {
            guard t.hasHardwareOption, s.hardware, !runner.isCancelled else { throw error }
            var software = s
            software.hardware = false
            try await encode(software)
        }
    }
}
