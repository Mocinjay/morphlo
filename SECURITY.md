# Security Policy

## Supported versions

Security fixes land on the latest release of Morphlo. Please update
(`brew upgrade --cask morphlo`, `npx morphlo`, or the latest
[Morphlo.dmg](https://github.com/Mocinjay/morphlo/releases/latest/download/Morphlo.dmg))
before reporting an issue against an older version.

| Version | Supported |
|---|---|
| latest `0.1.x` | Yes |
| anything older | No |

## Reporting a vulnerability

**Please do not post details of a security problem in a public issue.**

Report it privately through GitHub: open the repository's
[**Security** tab](https://github.com/Mocinjay/morphlo/security) →
**Report a vulnerability**. Only the maintainer can see the report.

Include as much of this as you can:

- macOS version and Morphlo version (menu → About, or the release you installed)
- what you did, and the smallest file or steps that trigger the problem
- what happened, and what you expected

Once a fix ships, the advisory is published with credit to the reporter,
unless you ask to stay anonymous.

## What Morphlo can access, and why

| Permission | Required? | Why |
|---|---|---|
| **Photos** (Full Access) | For the automatic fix | Reads the original photo or video behind a drag out of Photos, by its library ID. Morphlo never writes to your library. |
| **Accessibility** | Optional | Spots AI-chat tabs in browsers and detects drags onto the Dock. Off until you grant it. |
| **Automation → Finder** (Apple Events) | Optional | Reads the current Finder selection when you press ⌥⌘K. Nothing else. |
| **Speech recognition** | Optional | On-device video transcripts (`requiresOnDeviceRecognition`). Audio never leaves the Mac. |

Morphlo has no accounts, analytics, telemetry, crash reporter or auto-updater.
Converted files are written next to the original (or to Downloads), and
temporary work files live in Morphlo's own folders.

## The no-network guarantee

Morphlo never connects to the internet. Every conversion uses frameworks that
ship with macOS (ImageIO, AVFoundation, Core Audio, PDFKit, TextKit) and
`/usr/bin` tools (`afconvert`, `textutil`). The source contains no networking
APIs, and CI fails if one is added.

The one exception is opt-in and not Morphlo's own traffic: if you turn on
"Get originals from iCloud Photos when needed" (off by default since 0.1.3),
Apple Photos may download an original that lives only in iCloud.

### Verify it yourself

With Morphlo running, list its open network sockets:

```sh
lsof -nP -a -p "$(pgrep -x Morphlo)" -i
```

No output means no sockets. Try it mid-drag and mid-conversion too. You can
also check the source (the same check CI runs; no output means nothing found):

```sh
grep -rEn 'URLSession|URLRequest|NSURLConnection|NWConnection|NWBrowser|import (Network|WebKit|SafariServices)\b|CFSocket|CFStream|WKWebView|getaddrinfo|\bsocket\(|/usr/bin/(curl|nc|ssh|scp|sftp|ftp)' Sources
```

## Scope

In scope: problems in Morphlo's own code, for example a crafted file that
makes a converter read or write outside the expected folders, a converted
copy replacing or deleting an original it shouldn't, full file paths or file
contents leaking into the log, or any network access.

Out of scope: bugs in macOS frameworks themselves (please report those to
Apple), and ordinary conversion or drag bugs, which are welcome as regular
[bug reports](https://github.com/Mocinjay/morphlo/issues/new?template=bug_report.md).
