**Test build — thanks for trying Morphlo!** Never worry about converting again.

### Install (about 1 minute)
1. Download **Morphlo.dmg** below and open it.
2. Drag **Morphlo** into **Applications**.
3. Open Morphlo from Applications. macOS will say it can't verify the developer. This test build isn't notarized by Apple yet, so that's expected. Click **Done**.
4. Open **System Settings → Privacy & Security**, scroll down to the "Morphlo was blocked" message, and click **Open Anyway**. Confirm with your password or Touch ID.
5. Look for the 🦋 butterfly in your menu bar. Click **Allow Full Access** when it asks about Photos.

Prefer Terminal? This does the same as steps 3–4:
```bash
xattr -dr com.apple.quarantine /Applications/Morphlo.app && open /Applications/Morphlo.app
```

### Try it
- **Drag a photo or video out of Photos** into Claude, ChatGPT, Gmail, or any upload box. It arrives as a real JPEG or the real video, with nothing to click.
- **Click the butterfly** → drop any file on the circle → pick a format on the wheel.
- **Right-click any file in Finder** → Quick Actions → **Convert with Morphlo**. Or select a file and press **⌥⌘K**.
- **Right-click the butterfly** for settings: keep or replace originals, the shelf, video options.

### Private by design
Everything runs on your Mac using built-in macOS frameworks. No internet access, no accounts, no analytics, nothing else to install.

Requires macOS 14 Sonoma or later (Apple Silicon or Intel). Found a bug? Open an issue and attach `~/Library/Logs/Morphlo/morphlo.log`.
