import AppKit
import UniformTypeIdentifiers

/// One thing dropped on Morphlo, before it has been turned into a local file.
enum DropSource {
    /// A file promise (what Photos.app hands out). Browsers ignore these; Morphlo fulfils them.
    case promise(PromiseFetch)
    case file(URL)
    case data(Data, UTType)

    var displayName: String {
        switch self {
        case .promise(let p): return p.displayName
        case .file(let u): return u.lastPathComponent
        case .data(_, let t): return "Pasted \(t.localizedDescription ?? "image")"
        }
    }
}

/// Starts receiving a promise immediately (it must begin inside performDragOperation) and lets
/// callers await the delivered files later.
final class PromiseFetch {
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        q.name = "morphlo.promises"
        return q
    }()

    let displayName: String
    private let lock = NSLock()
    private var urls: [URL] = []
    private var errors: [String] = []
    private var finished = false
    private var waiters: [CheckedContinuation<([URL], [String]), Never>] = []

    init(receiver: NSFilePromiseReceiver, destination: URL, timeout: TimeInterval = 300) {
        let types = receiver.fileTypes.compactMap { UTType($0) }
        if types.contains(where: { $0.conforms(to: .movie) }) { displayName = "Video from Photos" }
        else if types.contains(where: { $0.conforms(to: .image) }) { displayName = "Photo from Photos" }
        else { displayName = receiver.fileNames.first ?? "Promised file" }

        let expected = max(1, receiver.fileTypes.count)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        Log.write("Receiving promise: types=\(receiver.fileTypes) names=\(receiver.fileNames)")
        receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: Self.queue) { [weak self] url, error in
            guard let self else { return }
            self.lock.lock()
            if let error { self.errors.append(error.localizedDescription) } else { self.urls.append(url) }
            let done = self.urls.count + self.errors.count >= expected
            self.lock.unlock()
            Log.write("Promise delivered: \(url.lastPathComponent) error=\(error?.localizedDescription ?? "none")")
            if done { self.finish() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.urls.isEmpty && self.errors.isEmpty { self.errors.append("Timed out waiting for Photos") }
            self.lock.unlock()
            self.finish()
        }
    }

    private func finish() {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let result = (urls, errors)
        let w = waiters
        waiters = []
        lock.unlock()
        w.forEach { $0.resume(returning: result) }
    }

    func wait() async -> ([URL], [String]) {
        await withCheckedContinuation { c in
            lock.lock()
            if finished {
                let result = (urls, errors)
                lock.unlock()
                c.resume(returning: result)
            } else {
                waiters.append(c)
                lock.unlock()
            }
        }
    }
}

enum DropIntake {
    static let promiseTypes: [NSPasteboard.PasteboardType] =
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    static let imageDataTypes: [(NSPasteboard.PasteboardType, UTType)] = [
        (.heic, .heic), (.heif, .heif), (.png, .png), (.jpeg, .jpeg), (.tiff, .tiff),
    ]

    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        promiseTypes + [.fileURL] + imageDataTypes.map(\.0)
    }

    static func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Should the shelf pop up for this in-progress drag?
    static func isInteresting(_ pb: NSPasteboard) -> Bool {
        let types = Set(pb.types ?? [])
        if types.contains(.morphloMarker) { return false }
        if !types.isDisjoint(with: promiseTypes) { return true }
        if types.contains(.heic) || types.contains(.heif) { return true }
        // Only look at file extensions here: this runs during other apps' drags.
        return fileURLs(pb).contains { url in
            guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
            return t.conforms(to: .movie) || (t.conforms(to: .image) && !ImageConverter.isNative(t))
        }
    }

    /// Must be called synchronously from performDragOperation: promises have to be requested
    /// while the drag is still alive.
    static func collect(from pb: NSPasteboard, workDir: URL) -> [DropSource] {
        Log.write("Drop received:\n" + Log.describe(pb))

        // Apple's guidance: handle promises before file URLs. Photos puts a promise for the real
        // original plus a file URL for a low-res derivative (for videos, a poster JPEG).
        let receivers = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? []
        if !receivers.isEmpty {
            return receivers.enumerated().map { i, r in
                .promise(PromiseFetch(receiver: r, destination: workDir.appendingPathComponent("in-\(i)")))
            }
        }

        let urls = fileURLs(pb)
        if !urls.isEmpty { return urls.map { .file($0) } }

        for (type, uti) in imageDataTypes {
            if let data = pb.data(forType: type) { return [.data(data, uti)] }
        }
        return []
    }

    /// Turns a source into local input files.
    static func resolve(_ source: DropSource, workDir: URL) async -> ([URL], [String]) {
        switch source {
        case .promise(let p): return await p.wait()
        case .file(let u): return ([u], [])
        case .data(let data, let type):
            let url = WorkDir.unique(in: workDir.appendingPathComponent("in"), base: "Pasted image",
                                     ext: type.preferredFilenameExtension ?? "img")
            do { try data.write(to: url); return ([url], []) }
            catch { return ([], [error.localizedDescription]) }
        }
    }
}
