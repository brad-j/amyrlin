# amyrlin

A native macOS client for pi-durable agents. Each machine runs its own server; the app connects to each over one WebSocket on the tailnet. The wire format is in `docs/protocol.md`.

## Layout

| Path | What |
|---|---|
| `AmyrlinCore/` | SwiftPM package: protocol types, reducer, connection, stores. No AppKit or SwiftUI. |
| `App/` | The SwiftUI app. Thin; imports AmyrlinCore. |
| `project.yml` | XcodeGen spec. `Amyrlin.xcodeproj` is generated; do not edit it. |
| `docs/protocol.md` | Protocol v1, the contract the server implements. |
| `fixtures/durable-1.1.0/` | Recorded pi-durable event streams, with a README on how each was made. |
| `fixtures/wire-v1/` | The same streams translated to protocol v1 by `tools/mock-server/translate.mjs`. |
| `tools/mock-server/` | A Node mock server that speaks v1, replays the fixtures and runs scripted live conversations. |
| `scratch/recorder/` | The fixture recorder. |

## Commands

```sh
# Core tests
cd AmyrlinCore && swift test

# App
xcodegen generate
xcodebuild -project Amyrlin.xcodeproj -scheme Amyrlin -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Amyrlin.app

# Mock server (the app adds ws://127.0.0.1:8787/amyrlin on first launch)
cd tools/mock-server && node server.mjs
node smoke.mjs                                    # protocol smoke test against a running server
curl -X POST http://127.0.0.1:8787/debug/drop     # break every connection, to watch reconnects
pnpm run export-wire                              # regenerate fixtures/wire-v1 after re-recording

# Fixtures
cd scratch/recorder && pnpm run record
python3 -I ../tools/check_fixtures.py ../../fixtures/durable-1.1.0
python3 -I ../tools/check_citations.py ../../docs/protocol.md ../../fixtures/durable-1.1.0
```

In the mock, live conversations answer by keyword: "count" runs a streaming tool, "delete" asks for approval, "long" or "explain" writes a long answer.
