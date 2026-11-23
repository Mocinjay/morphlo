## What this changes

<!-- One or two sentences. Link the issue if there is one. -->

## How I tested it

<!-- Which drag cases from CONTRIBUTING.md did you run? Source app → destination app, macOS version. -->

## Checklist

- [ ] `swift build -c release` passes with no new warnings (3 known ones in `FormatWheel.swift`)
- [ ] No networking APIs, no new dependencies, only built-in frameworks and `/usr/bin` tools
- [ ] No new formats macOS can't encode natively
- [ ] Originals are never lost (copies next to the file; "replace" goes to the Trash)
- [ ] User-facing change noted under `Unreleased` in `CHANGELOG.md`
