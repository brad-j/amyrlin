# amyrlin

A native macOS client for pi-durable agents. The app connects to each host over one WebSocket on the tailnet and speaks protocol v1 (`docs/protocol.md`). The host it's built for is [aludra](https://github.com/brad-j/aludra), which serves v1 at `wss://aludra.<tailnet>.ts.net/amyrlin` next to its phone app, so the same sessions show on both.

## Layout

| Path | What |
|---|---|
| `AmyrlinCore/` | SwiftPM package: protocol types, reducer, connection, stores. No AppKit or SwiftUI. |
| `App/` | The SwiftUI app. Thin; imports AmyrlinCore. |
| `project.yml` | XcodeGen spec. `Amyrlin.xcodeproj` is generated; do not edit it. |
| `docs/protocol.md` | Protocol v1, the contract the server implements. |
| `fixtures/durable-1.1.0/` | Recorded pi-durable event streams, with a README on how each was made. |
| `fixtures/wire-v1/` | The same streams translated to protocol v1 by aludra's `src/amyrlin/translate.ts` (its `scripts/amyrlin-export-wire.ts`). |
| `fixtures/server-v1/` | A session recorded from aludra's `/amyrlin` endpoint with a faux model (aludra's `scripts/amyrlin-capture.ts`), checked by a Swift test. |
| `scratch/recorder/` | The fixture recorder. |

## Commands

```sh
# Core tests
cd AmyrlinCore && swift test

# App: install a release build in /Applications (and reopen it)
sh scripts/install.sh

# App: a debug build, run from the build folder
xcodegen generate
xcodebuild -project Amyrlin.xcodeproj -scheme Amyrlin -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Amyrlin.app

# Fixtures
cd scratch/recorder && pnpm run record
python3 -I ../tools/check_fixtures.py ../../fixtures/durable-1.1.0
python3 -I ../tools/check_citations.py ../../docs/protocol.md ../../fixtures/durable-1.1.0
# then, from an aludra checkout beside this repo, regenerate fixtures/wire-v1
node --no-warnings scripts/amyrlin-export-wire.ts ../amyrlin/fixtures
```
