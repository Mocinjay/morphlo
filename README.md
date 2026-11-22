# Morphlo

### Never worry about converting again.

**Drag photos and videos out of Apple Photos into anything, and they just work. Click any file to turn it into any format.**

Morphlo is a free, open-source menu-bar app for macOS. It does two things:

1. **Fixes drags out of Photos, automatically.** On a Mac, dragging out of the Photos app into Chrome, the Claude or ChatGPT desktop apps, Slack, Discord, Dropbox, Gmail or any upload form goes wrong:
   - photos arrive as **`.heic`**, which most sites and AI chats can't read, or as a shrunken preview;
   - videos arrive as **a single still image** of the first frame.

   With Morphlo running, you just drag as usual. The file that lands is a full-quality JPEG, or the real video.
2. **Converts any file to any format, with a wheel.** Click a file and a ring of every format it can become pops up around your cursor. Pick one; the converted file appears next to the original.

Everything runs on your Mac with built-in macOS frameworks. Nothing is uploaded, there are no analytics or accounts, and there are no extra tools to install. Morphlo never touches the network. If you use iCloud Photos with "Optimize Mac Storage", you can optionally let macOS fetch originals that live only in your iCloud (right-click 🦋 → "Get originals from iCloud Photos when needed"). It's off by default.

## The convert wheel

Open it any of these ways:

- **Menu bar:** click the butterfly and a round drop zone opens under it. Drop any file (from Finder, or straight from Photos), or click it to choose.
- **Finder:** right-click files → **Quick Actions** (or **Services**) → **Convert with Morphlo**
- **Shortcut:** select files in Finder and press **⌥⌘K**
- **Shelf:** click any file on Morphlo's shelf
- Drop files on Morphlo's app icon, or right-click the menu-bar icon → **Convert a File…**

| From | To |
|---|---|
| Images (HEIC, JPEG, PNG, TIFF, RAW, …) | JPEG, PNG, HEIC, AVIF, TIFF, GIF, BMP, PDF |
| Video (MOV, MP4, M4V, 3GP, …) | MP4 (H.264), MP4 (HEVC), MOV (ProRes), animated GIF, or audio only |
| Audio (M4A, MP3, WAV, AIFF, FLAC, CAF, …) | M4A (AAC), M4A (HE-AAC), WAV, AIFF, FLAC, ALAC (Apple Lossless) |
| Documents (Markdown, Word, ODT, RTF, HTML, TXT) | PDF, DOCX, DOC, ODT, RTF, TXT, HTML |
| PDF | PNG or JPEG per page, DOCX / ODT / RTF / TXT (text) |
| Fonts (TTF, OTF, WOFF, WOFF2) | WOFF2, WOFF, TTF/OTF |

**100% local, nothing else to install.** Every conversion uses frameworks that ship with macOS: ImageIO, AVFoundation, Core Audio, PDFKit, TextKit and Apple's Brotli. Morphlo never calls Homebrew tools or the internet. Formats macOS can't encode by itself (MP3, WebM, MKV, OGG, WebP) aren't offered.

## How the automatic fix works

Photos doesn't hand over real files when you drag. It hands over **file promises** ("ask me and I'll export the original") plus a small preview file. Chrome and Electron apps (the Claude and ChatGPT desktop apps, Slack, Discord, VS Code…) never ask for the promise. Chromium's macOS drop code takes the preview instead, so HEIC or a downsized JPEG arrives, and a video becomes its poster frame.

Every drag out of Photos also carries the item's library ID. The moment a drag starts, Morphlo:

1. fetches the full original from your library through Apple's Photos API;
2. converts it: HEIC becomes JPEG, a video stays the real file;
3. swaps the fixed file into the drag once the cursor leaves Photos, before the destination reads it.

A photo is usually ready in 0.1–0.3 s, well before your cursor reaches the other window. Each destination gets what suits it:

- **Finder, Mail, Messages, Notes:** the untouched original (they already handle Photos correctly).
- **AI chats (Claude, ChatGPT, Gemini…):** the real video, or a contact sheet plus frames if you switch that on in settings.
- **Everything else:** a JPEG for photos, the real video for videos.
- **Inside Photos** (e.g. dragging into an album): never touched.

If an original is only in iCloud and iCloud fetching is off, or it isn't ready in time, the drag carries what Photos itself provides.

## Install

Pick one:

- **Download:** [**Morphlo.dmg**](https://github.com/Mocinjay/morphlo/releases/latest/download/Morphlo.dmg). Open it and drag Morphlo to Applications.
- **Homebrew:**
  ```bash
  brew tap mocinjay/tap && brew trust mocinjay/tap && brew install --cask morphlo
  ```
- **npx** (downloads the signed app from GitHub Releases and opens it):
  ```bash
  npx morphlo
  ```

Website: https://mocinjay.github.io/morphlo

Requires macOS 14 Sonoma or later; native on Apple Silicon and Intel. Nothing else to install.

On first launch macOS asks for **Photos** access (needed for the automatic fix; choose Full Access). Optional permissions:

- **Accessibility:** lets Morphlo spot AI-chat tabs in browsers.
- **Speech recognition:** for video transcripts.
- **Finder automation:** for ⌥⌘K.

Uninstall: `brew uninstall --cask morphlo`, `npx morphlo uninstall`, or drag Morphlo.app to the Trash.

## Settings

Right-click the menu-bar icon:

- convert wheel: keep the original (save a new file) or replace it (original goes to the Trash); hold ⌥ while picking a format to do the other once
- automatic fix on/off
- shelf pop-up
- video output for AI chats
- frame count
- transcripts
- photo size
- clipboard HEIC fix
- launch at login
- log

## Command line

```bash
/Applications/Morphlo.app/Contents/MacOS/Morphlo --convert-to jpg IMG_0001.HEIC     # any-format conversion
/Applications/Morphlo.app/Contents/MacOS/Morphlo --targets clip.mov                 # list format ids
/Applications/Morphlo.app/Contents/MacOS/Morphlo --convert IMG_0002.MOV --out ./ai  # AI-friendly: frames + contact sheet
```

## Build from source

```bash
./scripts/build-app.sh                 # universal build/Morphlo.app, signed with your best local identity
VERSION=0.1.0 ./scripts/release.sh     # Developer ID sign, notarize, staple, zip (see the script header)
```

## Troubleshooting

The log is at `~/Library/Logs/Morphlo/morphlo.log` (menu → **Open log**). It records what each drag carried (types, not file paths) and every conversion. Please attach it to bug reports.

## Credits

The convert-any-file engine is adapted from [Convert](https://github.com/newtonstudios/convert) by eliasdesena (MIT). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

MIT
