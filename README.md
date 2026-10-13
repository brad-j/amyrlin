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
| `fixtures/wire-v1/` | The same streams translated to protocol v1 by `server/src/translate.mjs`. |
| `server/` | A standalone v1 server on pi-durable with an API key. Superseded by aludra's endpoint; kept for the translator, `export-wire` and its tests. |
| `fixtures/server-v1/` | A session recorded from aludra's `/amyrlin` endpoint with a faux model (aludra's `scripts/amyrlin-capture.ts`), checked by a Swift test. |
| `scratch/recorder/` | The fixture recorder. |

## Commands

```sh
# Core tests
cd AmyrlinCore && swift test

# App
xcodegen generate
xcodebuild -project Amyrlin.xcodeproj -scheme Amyrlin -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Amyrlin.app

# Server, locally with the faux model (no key; ws://127.0.0.1:8421/amyrlin)
cd server && pnpm run dev
node test/e2e.mjs                                 # end-to-end test against it
node test/capture.mjs                             # re-record fixtures/server-v1/session.jsonl
pnpm run export-wire                              # regenerate fixtures/wire-v1 after re-recording fixtures

# Server on a Linux machine (systemd user service, then: tailscale serve --bg 8420)
AMYRLIN_LOGIN=you@example.com sh server/deploy/setup.sh

# Fixtures
cd scratch/recorder && pnpm run record
python3 -I ../tools/check_fixtures.py ../../fixtures/durable-1.1.0
python3 -I ../tools/check_citations.py ../../docs/protocol.md ../../fixtures/durable-1.1.0
```
