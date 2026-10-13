# amyrlin

A native macOS client for coding agents running on your own machines. Each machine runs [aludra](https://github.com/brad-j/aludra), which serves protocol v1 (`docs/protocol.md`) at `wss://<machine>.<tailnet>.ts.net/amyrlin` next to its phone app, so the same sessions show on both. The app connects to every machine you add, over one WebSocket each on the tailnet.

## Setup

1. On each machine whose projects you want, install aludra and run it as a service (its README has the details):

   ```sh
   git clone git@github.com:brad-j/aludra.git && cd aludra
   sh scripts/install.sh
   aludra init
   aludra service install
   tailscale serve --bg 8724
   ```

   `aludra doctor` checks the machine and prints the address to add.
2. Build and install the app on this Mac (needs Xcode and XcodeGen): `sh scripts/install.sh`.
3. In the app, add each machine by its address, `wss://<machine>.<tailnet>.ts.net/amyrlin`, or just its tailnet name.
   A machine that can't connect says why under its name in the sidebar.

The app is signed for this Mac only (ad hoc, no Developer ID). To use it on another Mac, build it there, or copy
`/Applications/Amyrlin.app` across. If it was copied in a way that marks it as downloaded (AirDrop, a browser), macOS
refuses to open it the first time: open it once, then allow it in System Settings → Privacy & Security → Open Anyway,
or run `xattr -dr com.apple.quarantine /Applications/Amyrlin.app`. Copies made with `scp` or `rsync` open directly.

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
