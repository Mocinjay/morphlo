import AppKit
import AVFoundation
import Photos
import SwiftUI

/// The welcome tour: four short slides, each with a silent looping clip from the demo video.
/// Shown once, on first launch, and again from the menu ("Welcome Tour…").
///
/// macOS's Photos permission prompt waits until the tour is finished, so it never lands on top of
/// the welcome window. The last slide says it's coming and why.
@MainActor
final class Onboarding: NSObject, NSWindowDelegate {
    static let shared = Onboarding()

    private static let doneKey = "onboardingDone"
    static var isDone: Bool {
        get { UserDefaults.standard.bool(forKey: doneKey) }
        set { UserDefaults.standard.set(newValue, forKey: doneKey) }
    }

    /// Runs once when the tour is finished or closed (the first time only).
    var onFinish: (() -> Void)?

    private var window: NSWindow?
    private let model = OnboardingModel()

    func show() {
        model.page = 0
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        model.finish = { [weak self] in self?.window?.close() }
        // Fit short screens (e.g. 13" at "Larger Text"): the clip shrinks, the buttons stay visible.
        let visible = (NSScreen.main?.visibleFrame.height ?? 900) - 28 - 12
        model.height = max(420, min(640, visible))
        let host = NSHostingView(rootView: OnboardingView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: model.height),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to Morphlo"
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua) // matches the clips
        window.backgroundColor = NSColor(white: 0.06, alpha: 1)
        window.contentView = host
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Log.write("Welcome tour shown")
    }

    func windowWillClose(_ notification: Notification) {
        model.stopVideo()
        window = nil
        let firstTime = !Self.isDone
        Self.isDone = true
        Log.write("Welcome tour closed on slide \(model.page + 1) of \(OnboardingModel.slides.count)")
        if firstTime { onFinish?() }
    }
}

// MARK: - Content

struct OnboardingSlide {
    enum Tone { case bad, good, neutral }
    let clip: String
    let badge: String
    let tone: Tone
    let title: String
    let body: String
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var page = 0
    var height: CGFloat = 640
    var finish: () -> Void = {}
    var stopVideo: () -> Void = {}

    static var slides: [OnboardingSlide] {
        let disc = Settings.openDiscShortcut.map { ", press \($0.display)" } ?? ""
        let trigger = Settings.dragTrigger == .off ? "" : "Tap \(Settings.dragTrigger.title) while dragging a file"
        let wheelWays = trigger.isEmpty
            ? "Click the butterfly in the menu bar\(disc), select files in Finder and press ⌥⌘K, or right-click → Quick Actions → Convert with Morphlo."
            : "\(trigger), click the butterfly in the menu bar\(disc), or right-click a file → Quick Actions → Convert with Morphlo."
        let result = Settings.replaceOriginal
            ? "Pick a format from the wheel and the converted file takes the original's place (the original goes to the Trash)."
            : "Pick a format from the wheel and the new file is saved next to the original, or in Downloads if it came from Photos or a browser."
        let videos = Settings.videoForAI == .video ? "videos as the real video" : "videos as still frames for AI chats"
        let fix = Settings.autoFix
            ? "Photos arrive as JPEG and \(videos). No clicks, no pop-ups."
            : "Photos arrive as JPEG and \(videos). Turn on Auto-fix drags in the menu to make it automatic."
        let local = Settings.useICloudOriginals
            ? "Morphlo lives in your menu bar and runs on your Mac. It only goes online to fetch your own originals from iCloud Photos, because you turned that on. Nothing is uploaded, no accounts, no tracking."
            : "Morphlo lives in your menu bar and runs 100% on your Mac. It never connects to the internet: nothing is uploaded, no accounts, no tracking."
        return [
            OnboardingSlide(
                clip: "1-before", badge: "Without Morphlo", tone: .bad,
                title: "Welcome to Morphlo",
                body: "iPhone photos are HEIC, and lots of websites and AI chats reject them. Videos often arrive as a single still frame. Morphlo fixes both, right on your Mac."),
            OnboardingSlide(
                clip: "2-fix", badge: "With Morphlo", tone: .good,
                title: "Just drag. It just works.",
                body: "Drag photos and videos from Photos, Finder, the Desktop or the Dock into Claude, ChatGPT, Gmail or any upload box. \(fix)"),
            OnboardingSlide(
                clip: "3-convert", badge: "Convert wheel", tone: .neutral,
                title: "Any file, any format.",
                body: "\(wheelWays) \(result)"),
            OnboardingSlide(
                clip: "4-everywhere", badge: "Works everywhere", tone: .neutral,
                title: "You're all set.",
                body: local),
        ]
    }
}

// MARK: - Views

private let accent = Color(red: 0x8b / 255, green: 0x6c / 255, blue: 0xf6 / 255)

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    private let slides = OnboardingModel.slides
    private var isLast: Bool { model.page == slides.count - 1 }

    var body: some View {
        let slide = slides[model.page]
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                LoopingClip(name: slide.clip, model: model)
                    .id(slide.clip)
                    .transition(.opacity)
                    .accessibilityHidden(true)
                Badge(text: slide.badge, tone: slide.tone)
                    .padding(12)
                    .id("badge-\(model.page)")
                    .transition(.opacity)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
            .layoutPriority(-1) // on short screens the clip shrinks first; text and buttons stay

            VStack(alignment: .leading, spacing: 10) {
                Text(slide.title)
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.4)
                    .accessibilityAddTraits(.isHeader)
                Text(slide.body)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                if isLast { PhotosNote() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 26)
            .id("text-\(model.page)")
            .transition(.opacity.combined(with: .offset(y: 6)))

            Spacer(minLength: 16)

            HStack {
                if model.page == 0 {
                    Button("Skip") { model.finish() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Back") { go(model.page - 1) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                }
                Spacer(minLength: 0)
                Button { isLast ? model.finish() : go(model.page + 1) } label: {
                    Text(isLast ? "Get Started" : "Next")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(accent, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .overlay { Dots(count: slides.count, page: model.page) { go($0) } } // stays centred
            .background {
                // Keyboard: → next, Esc closes the tour (hidden buttons carry the shortcuts).
                Group {
                    Button("") { if !isLast { go(model.page + 1) } }.keyboardShortcut(.rightArrow, modifiers: [])
                    Button("") { model.finish() }.keyboardShortcut(.cancelAction)
                }
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 44)
        .padding(.bottom, 26)
        .frame(width: 760, height: model.height)
        .background(
            RadialGradient(colors: [Color(white: 0.11), Color(white: 0.06)], center: .top, startRadius: 40, endRadius: 620)
        )
        .preferredColorScheme(.dark)
    }

    private func go(_ page: Int) {
        guard page >= 0, page < slides.count, page != model.page else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduce ? nil : .easeInOut(duration: 0.28)) { model.page = page }
    }
}

private struct Badge: View {
    let text: String
    let tone: OnboardingSlide.Tone
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.72), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .foregroundStyle(.white)
    }
    private var color: Color {
        switch tone {
        case .bad: return Color(red: 1, green: 0.42, blue: 0.42)
        case .good: return Color(red: 0.25, green: 0.87, blue: 0.53)
        case .neutral: return accent
        }
    }
}

private struct Dots: View {
    let count: Int
    let page: Int
    let select: (Int) -> Void
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Button { select(i) } label: {
                    Capsule()
                        .fill(i == page ? Color.white : Color.white.opacity(0.4))
                        .frame(width: i == page ? 18 : 7, height: 7)
                        .contentShape(Rectangle().inset(by: -6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Slide \(i + 1) of \(count)")
                .accessibilityAddTraits(i == page ? .isSelected : [])
            }
        }
        .animation(.easeInOut(duration: 0.25), value: page)
    }
}

/// On the last slide: what happens with Photos access when the tour closes.
private struct PhotosNote: View {
    var body: some View {
        if Settings.autoFix, let note = message {
            let (text, button) = note
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "photo.on.rectangle").foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if button {
                        Button("Open Photos Privacy Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 12.5))
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            .padding(.top, 6)
        }
    }

    private var message: (String, Bool)? {
        switch PhotoLibrary.status {
        case .notDetermined:
            return ("Next, macOS asks to let Morphlo read your Photos library. Choose Allow Full Access so it can fetch the originals of photos and videos you drag out of Photos.", false)
        case .denied, .restricted:
            return ("Photos access is off, so drags out of Photos can't be fixed. Turn on Morphlo in Privacy & Security → Photos.", true)
        default:
            return nil
        }
    }
}

/// A silent, looping clip with no controls (AVPlayerLayer).
private struct LoopingClip: NSViewRepresentable {
    let name: String
    let model: OnboardingModel

    func makeNSView(context: Context) -> ClipView {
        let view = ClipView()
        view.play(Self.url(for: name))
        model.stopVideo = { [weak view] in view?.stop() }
        return view
    }

    func updateNSView(_ view: ClipView, context: Context) {}

    static func dismantleNSView(_ view: ClipView, coordinator: ()) { view.stop() }

    /// Bundled at Contents/Resources/Onboarding; falls back to the repo folder for `swift run`.
    static func url(for name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "mp4", subdirectory: "Onboarding") { return url }
        // `swift run`: the binary sits in .build/<triple>/debug (or .build/debug); look up the tree.
        var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<4 {
            guard let d = dir else { break }
            let dev = d.appendingPathComponent("Resources/Onboarding/\(name).mp4")
            if FileManager.default.fileExists(atPath: dev.path) { return dev }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }
}

final class ClipView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func play(_ url: URL?) {
        guard let url else {
            Log.write("Welcome tour: clip missing from the app bundle")
            return
        }
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: item)
        playerLayer.player = player
        self.player = player
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Reduce Motion: a still from the middle of the clip instead of a loop.
            let asset = AVURLAsset(url: url)
            Task { @MainActor [weak self] in
                let duration = (try? await asset.load(.duration)) ?? .zero
                guard let self, let player = self.player else { return }
                player.pause()
                await player.seek(to: CMTimeMultiplyByRatio(duration, multiplier: 3, divisor: 5), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        } else {
            player.play()
        }
    }

    func stop() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        playerLayer.player = nil
    }
}
