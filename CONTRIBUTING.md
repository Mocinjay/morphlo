# Contributing to Morphlo

Morphlo makes every drag on a Mac just work and turns any file into any
format, 100% on-device. Bug fixes, new destination handling, and conversions
macOS can do natively are all welcome.

## Dev setup

Requires macOS 14 Sonoma or later and Xcode 16+ (Swift 6 toolchain). There
are no dependencies to install: the package uses only Apple frameworks.

```sh
swift build                     # debug build, fast compile check
./scripts/build-app.sh          # universal build/Morphlo.app, signed with your best local identity
open build/Morphlo.app
```

Quit any installed copy of Morphlo first, so two copies don't fight over the
drag pasteboard and the hot keys.

Logs go to `~/Library/Logs/Morphlo/morphlo.log` (menu → **Open log**). Watch
them live while testing:

```sh
tail -f ~/Library/Logs/Morphlo/morphlo.log
```

The command-line modes are handy for testing conversions without the UI:

```sh
build/Morphlo.app/Contents/MacOS/Morphlo --targets clip.mov              # format ids the wheel offers
build/Morphlo.app/Contents/MacOS/Morphlo --convert-to jpg IMG_0001.HEIC  # saved next to the original
build/Morphlo.app/Contents/MacOS/Morphlo --convert IMG_0002.MOV --out ./ai
```

## Project layout

| File | Purpose |
|---|---|
| `Sources/Morphlo/main.swift` | Entry point; command-line modes (`--convert`, `--convert-to`, `--targets`, internal PDF worker) or the menu-bar app |
| `Sources/Morphlo/AppDelegate.swift` | Menu-bar item, settings menu, shortcuts, opening the convert wheel, drops on the icon |
| `Sources/Morphlo/AutoFix.swift` | The zero-touch fix: where a drag is heading, fetching originals from Photos, swapping files into the drag |
| `Sources/Morphlo/Watchers.swift` | `DragWatcher` notices system-wide drags via the drag pasteboard; `ClipboardWatcher` adds JPEG/PNG next to HEIC on the clipboard |
| `Sources/Morphlo/DragSniffer.swift` | Near-invisible window that learns the Dock's private drag pasteboard name so Dock drags get fixed too |
| `Sources/Morphlo/Intake.swift` | Turns anything dropped on Morphlo (files, Photos file promises) into local files |
| `Sources/Morphlo/Converter.swift` | AI-friendly conversion: HEIC → JPEG, video → frames and contact sheet |
| `Sources/Morphlo/FormatWheel.swift` | The convert wheel: ring of target formats around the cursor, progress and result in the hub |
| `Sources/Morphlo/DropDisc.swift` | The round drop zone (menu bar, ⇧ mid-drag, ⌃⌥M) that hands off to the wheel |
| `Sources/Morphlo/Shelf.swift` | The shelf panel: tiles of converted files you can drag on |
| `Sources/Morphlo/Shortcuts.swift` | `KeyCombo` (stored shortcuts), the ⇧ mid-drag trigger detector, and the shortcut recorder |
| `Sources/Morphlo/HotKey.swift` | System-wide Carbon hot keys; reads the Finder selection via Apple Events for ⌥⌘K |
| `Sources/Morphlo/Transcriber.swift` | On-device speech-to-text for a video's audio track |
| `Sources/Morphlo/Icon.swift` | The butterfly mark, drawn as a menu-bar template image |
| `Sources/Morphlo/Support.swift` | Settings, logging, work directories, helpers |
| `Sources/Morphlo/Convert/` | Any-format engine adapted from [Convert](https://github.com/newtonstudios/convert) (MIT): formats, images (ImageIO), audio/video (`NativeAV`: AVFoundation + `afconvert`), documents (`textutil`, PDFKit, Markdown), fonts (SFNT, WOFF, WOFF2) |
| `scripts/build-app.sh` | Universal `.app` build and signing |
| `scripts/release.sh` | Developer ID signing, notarization, DMG/zip, checksums (maintainers) |

## Hard rules

- **100% local.** No networking APIs, ever: no `URLSession`, `URLRequest`,
  `Network.framework`, sockets, web views or shelling out to `curl`. CI fails
  if one appears in `Sources/`. The only network access anywhere is the
  optional, off-by-default iCloud originals fetch, which Apple Photos
  performs, not Morphlo.
- **Built-in macOS only.** Use frameworks that ship with macOS (ImageIO,
  AVFoundation, Core Audio, PDFKit, TextKit, Photos, Speech) and tools in
  `/usr/bin` (`afconvert`, `textutil`). No Homebrew tools, no bundled binaries,
  no Swift package dependencies.
- **Never offer a format macOS can't encode natively.** MP3, WebM, MKV, OGG and
  WebP stay out of the wheel until macOS can write them itself.
- **Never lose a user's file.** Converted copies go next to the original;
  "replace" moves the original to the Trash, never deletes it. Finder, Mail,
  Messages, Notes, the Desktop and the Trash always get the untouched original.
- **Keep the design neutral.** The wheel and disc follow Apple's radial-menu
  look: dark base, gray segments, thin dividers, no color except state.
- **No full paths or file contents in logs.** Log types, counts, timings and
  bare file names only (`lastPathComponent`), never `.path` or file data.

## Testing drags by hand

There are no automated UI tests for drags, so please run through the cases
your change touches before opening a PR:

1. **Photos → browser:** drag a HEIC photo and a video from Photos into a file
   upload box in Chrome or Safari. Expect a `.jpg` and the full video.
2. **Photos → Finder / Mail:** expect the untouched original (HEIC stays HEIC).
3. **Inside Photos:** drag into an album. Nothing should change.
4. **Finder → browser:** drag a HEIC out of Finder. Expect a `.jpg`.
5. **Dock stack → browser:** drag a HEIC out of the Downloads stack. Expect a
   `.jpg`. Repeat with an auto-hiding Dock and on a second display if you can.
6. **Dock stack → Desktop / Trash:** the original file moves, not a copy.
7. **⇧ mid-drag, ⌃⌥M, ⌥⌘K, right-click → Convert with Morphlo:** each opens
   the drop disc or wheel; convert one image, one video, one document.
8. Check `~/Library/Logs/Morphlo/morphlo.log` for errors.

## Pull request checklist

- [ ] `swift build -c release` passes with no new warnings
- [ ] No networking APIs, no new dependencies, only built-in frameworks and `/usr/bin` tools
- [ ] Relevant drag cases above tested by hand (say which in the PR)
- [ ] No new formats macOS can't encode natively
- [ ] User-facing change noted under `Unreleased` in [CHANGELOG.md](CHANGELOG.md)

(The current tree has 3 known warnings in `FormatWheel.swift`, about `weak self`
captures. Don't add more.)

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`,
`fix:`, `docs:`, `chore:`), scoped where helpful (e.g. `fix(autofix): ...`).

## Security issues

Report vulnerabilities privately. See [SECURITY.md](SECURITY.md).
