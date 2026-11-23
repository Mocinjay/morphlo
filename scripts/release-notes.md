**Never worry about converting again.**

Morphlo is a free menu-bar app for your Mac:

- **Drag straight out of Photos** into Claude, ChatGPT, Gmail, Dropbox or any upload box. Photos arrive as real JPEGs, and videos arrive as the real video instead of a still frame. You don't click anything.
- **Convert any file** to any format with the wheel:
  - Click the 🦋 in the menu bar and drop a file.
  - Or right-click a file in Finder → **Convert with Morphlo**.
  - Or select a file and press **⌥⌘K**.

### New in 0.1.4
- **A welcome tour.** The first time you open Morphlo, four short slides show what it does: drag a HEIC or a video straight into any chat or upload box, convert any file with the wheel, and everything stays on your Mac. Replay it anytime: right-click 🦋 → **Welcome Tour…**
- macOS asks for Photos access after the tour, instead of on top of it.

### New in 0.1.3
- **100% local by default.** Morphlo no longer asks Photos to fetch originals from iCloud unless you turn it on (right-click 🦋 → "Get originals from iCloud Photos when needed"). Out of the box, nothing ever touches the network.

### New in 0.1.2
- **Drags out of the Dock now get fixed automatically too.** Drag a HEIC out of your Downloads stack (or any file kept in the Dock) into Claude, ChatGPT or any website, and it arrives as a JPEG, just like drags from Finder and Photos.
- **Your originals stay put where they should.** Dropping a photo on the Desktop, the Trash or a Finder-type app icon in the Dock moves or trashes the real file, never Morphlo's converted copy. Dropping onto Claude's or a browser's Dock icon still gets the JPEG.
- Works with an auto-hiding Dock and on multiple displays.

### New in 0.1.1
- **Tap ⇧ Shift while dragging** any file and the drop disc pops up right under your cursor. You don't have to drag all the way to the menu bar. This works for every drag: Finder, Photos, and the Dock's Downloads stack.
- **⌃⌥M** opens the drop disc wherever your cursor is. Change it under right-click 🦋 → **Shortcuts**.
- **The Videos menu is clearer.** "Send the full video" vs "Send still frames" comes first.
- Drags out of Finder are detected more reliably.

### Install
Pick one:
- **Download** `Morphlo.dmg` below → open it → drag Morphlo to Applications. It's signed and notarized by Apple, so it opens with no warnings.
- **Homebrew:** `brew tap mocinjay/tap && brew trust mocinjay/tap && brew install --cask morphlo`
- **npx:** `npx morphlo`

On first launch, allow **Photos** access (Full Access). Morphlo needs it to grab your originals.

### Private by design
Everything runs on your Mac with built-in macOS frameworks. Morphlo never connects to the internet, and fetching originals from iCloud is off unless you switch it on. It has no accounts and no analytics, and you don't need to install anything else.

Requires macOS 14 Sonoma or later (Apple Silicon or Intel).
