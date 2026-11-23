# Changelog

All notable changes to Morphlo are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.5] - 2026-11-23

### Changed

- **The drop disc stays open.** Opened from the menu-bar butterfly or ⌃⌥M,
  it no longer closes on outside clicks. It closes on the butterfly again,
  the shortcut again, Esc, or a right-click. While the convert wheel is open
  it steps aside, and it comes back when the wheel closes.
- **Move the disc** by dragging its center. Tapping ⇧ mid-drag while it's
  open brings it under the cursor.

### Fixed

- Pressing on one of Morphlo's own windows (like dragging the disc) is no
  longer mistaken for a drag out of the Dock.

## [0.1.4] - 2026-11-23

### Added

- **Welcome tour.** On first launch Morphlo opens a four-slide tour, each slide
  with a short silent clip: the HEIC and video problem, the zero-touch fix, the
  convert wheel, and 100% local. Next / Back / dots, ← → Return and Esc work.
  Replay it from the menu (right-click 🦋 → "Welcome Tour…"). The text follows
  your settings (shortcuts, video mode, iCloud originals, replace original).

### Changed

- On first launch the macOS Photos permission prompt now appears after the
  tour is closed, so it never covers the tour.

## [0.1.3] - 2026-11-22

### Changed

- **100% local out of the box.** Fetching originals from iCloud Photos is now
  **off by default**. Morphlo no longer asks Photos to download originals that
  live only in iCloud unless you turn it on (right-click the menu-bar icon →
  "Get originals from iCloud Photos when needed"). With the default settings,
  nothing touches the network.

## [0.1.2] - 2026-11-22

### Added

- **Drags out of the Dock are fixed automatically.** The Dock gives each drag
  its own private, randomly named pasteboard instead of the shared drag
  pasteboard Finder and Photos use. Morphlo now catches that pasteboard
  (`DragSniffer`) and runs the normal auto-fix on it. A HEIC dragged out of
  the Downloads stack (or any file kept in the Dock) into Claude, ChatGPT or a
  website arrives as a JPEG.

### Fixed

- Dropping onto the Desktop, the Trash, or a Finder-type app icon in the Dock
  moves or trashes the **original** file, never Morphlo's converted copy.
  Dropping onto a browser's or an AI chat app's Dock icon still gets the JPEG.
- Dock-drag detection works with an auto-hiding Dock and on multiple displays.

## [0.1.1] - 2026-11-22

### Added

- **Tap ⇧ Shift mid-drag** and the circular drop disc pops up right under the
  cursor. Works for every drag: Finder, Photos, and Dock stacks.
- **⌃⌥M** (default, changeable) opens the drop disc wherever the cursor is.
- Configurable shortcuts: right-click the menu-bar icon → **Shortcuts**.

### Changed

- Homebrew install now includes `brew trust mocinjay/tap`; `npx morphlo` fixes.

### Fixed

- Drags out of Finder are detected more reliably.

## [0.1.0] - 2026-11-22

First public release.

### Added

- **Zero-touch drag fix for Apple Photos and Finder.** Drag out of Photos
  into any app or website: HEIC photos arrive as full-quality JPEG and videos arrive as the
  real video (every frame and the audio) instead of a single still frame.
  Morphlo fetches the original through the Photos API and swaps it into the
  drag before the destination reads it. Finder, Mail, Messages and Notes get
  the untouched original; drags inside Photos are never touched.
- HEIC/TIFF dragged out of Finder is converted on the fly too.
- Originals that live only in iCloud Photos are fetched through Apple Photos
  (on by default; turned off by default in 0.1.3).
- Copying a HEIC adds a JPEG/PNG version to the clipboard.
- The **Videos** menu is clearer: "Send the full video" vs "Send still frames"
  comes first.
- **Convert wheel.** A ring of every format a file can become, around the
  cursor. Images, video, audio, documents, PDF and fonts, using only built-in
  macOS frameworks. Keep the original or replace it (hold ⌥ to flip once).
- **Drop disc.** Click the butterfly in the menu bar and drop any file.
- **Finder Quick Action** (right-click → Convert with Morphlo) and **⌥⌘K** for
  the Finder selection.
- Optional AI-chat mode: still frames plus a contact sheet instead of video.
- Optional on-device video transcripts.
- Command line: `--convert-to`, `--targets`, `--convert`.
- Signed with Developer ID and notarized by Apple.
- Install via [Morphlo.dmg](https://github.com/Mocinjay/morphlo/releases/latest/download/Morphlo.dmg),
  Homebrew (`brew install --cask morphlo` from `mocinjay/tap`) or `npx morphlo`.

Pre-releases (such as the unnotarized `v0.1.0-beta.1` test build) are not listed.

[Unreleased]: https://github.com/Mocinjay/morphlo/compare/v0.1.5...HEAD
[0.1.5]: https://github.com/Mocinjay/morphlo/releases/tag/v0.1.5
[0.1.4]: https://github.com/Mocinjay/morphlo/releases/tag/v0.1.4
[0.1.3]: https://github.com/Mocinjay/morphlo/releases/tag/v0.1.3
[0.1.2]: https://github.com/Mocinjay/morphlo/releases/tag/v0.1.2
[0.1.1]: https://github.com/Mocinjay/morphlo/releases/tag/v0.1.1
[0.1.0]: https://github.com/Mocinjay/morphlo/releases/tag/v0.1.0
