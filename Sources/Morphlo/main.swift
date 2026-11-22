import AppKit

// Command-line modes (no UI). Each starts its work in a Task and parks the main thread in
// dispatchMain() so main-actor work (AppKit text layout for PDFs) can still run.
//
//   Morphlo --convert <files…> [--out <dir>]     AI-friendly conversion (HEIC→JPEG, video→frames)
//   Morphlo --convert-to <format-id> <files…>   any-file conversion, saved next to each original
//   Morphlo --targets <files…>                  list the format ids the wheel offers for these files
//   Morphlo --pdf-worker <in> <out> <a4|letter> internal: lays a document out as PDF in a child process
let args = Array(CommandLine.arguments.dropFirst())
DocConv.worker = Bundle.main.executableURL

func finish(_ ok: Bool) -> Never { exit(ok ? 0 : 1) }

switch args.first {
case "--convert":
    Settings.registerDefaults()
    Transcriber.mayPrompt = false
    var files: [URL] = []
    var outDir = FileManager.default.currentDirectoryPath + "/morphlo-out"
    var i = 1
    while i < args.count {
        if args[i] == "--out", i + 1 < args.count { outDir = args[i + 1]; i += 2; continue }
        files.append(URL(fileURLWithPath: args[i]))
        i += 1
    }
    let out = URL(fileURLWithPath: outDir, isDirectory: true)
    Task {
        var ok = true
        for f in files {
            do {
                for u in try await Converter.convert(f, outDir: out) { print(u.path) }
            } catch {
                FileHandle.standardError.write("\(f.lastPathComponent): \(error.localizedDescription)\n".data(using: .utf8)!)
                ok = false
            }
        }
        finish(ok)
    }
    dispatchMain()

case "--convert-to":
    guard args.count >= 3, let target = Targets.byID(args[1]) else {
        print("usage: Morphlo --convert-to <format-id> <files…>\nformats: \(Targets.all.map(\.id).joined(separator: " "))")
        exit(2)
    }
    Task {
        var ok = true
        for path in args.dropFirst(2) {
            let url = URL(fileURLWithPath: path).absoluteURL
            let start = Date()
            do {
                let outs = try await FormatConverter.convert(url, to: target, settings: ConvSettings(), runner: Runner()) { _ in }
                print(String(format: "OK   %@ → %@ (%.2fs)", url.lastPathComponent,
                             outs.map(\.lastPathComponent).joined(separator: ", "), Date().timeIntervalSince(start)))
            } catch {
                ok = false
                print("FAIL \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        finish(ok)
    }
    dispatchMain()

case "--targets":
    let urls = args.dropFirst().map { URL(fileURLWithPath: $0) }
    let kinds = Set(urls.compactMap(MediaKind.of))
    guard kinds.count > 0, urls.allSatisfy({ MediaKind.of($0) != nil }) else { print("unsupported file"); exit(1) }
    for (_, targets) in Targets.groups(for: kinds) { for t in targets { print(t.id) } }
    exit(0)

case "--pdf-worker":
    guard args.count == 4, ["a4", "letter"].contains(args[3]) else {
        FileHandle.standardError.write(Data("usage: Morphlo --pdf-worker <input> <output> <a4|letter>\n".utf8))
        exit(2)
    }
    Task { @MainActor in
        do {
            try DocConv.layOutPDF(URL(fileURLWithPath: args[1]), URL(fileURLWithPath: args[2]), a4: args[3] == "a4")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()

default:
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // `defaults write io.github.mocinjay.morphlo debugRegularApp -bool true` shows a Dock icon (debugging aid).
        app.setActivationPolicy(UserDefaults.standard.bool(forKey: "debugRegularApp") ? .regular : .accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
