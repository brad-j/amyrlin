# Prints what each fixture line cited in a document holds, so citations can be rechecked after re-recording.
# Usage: python3 -I check_citations.py docs/protocol.md fixtures/durable-1.1.0
import json, pathlib, re, sys

doc = pathlib.Path(sys.argv[1]).read_text()
fx = pathlib.Path(sys.argv[2])
seen = []
for m in re.finditer(r"`(\d\d-[a-z0-9.-]+):(\d+)`(?: to `:(\d+)`)?", doc):
    f, a, b = m.group(1), int(m.group(2)), m.group(3)
    for ln in range(a, (int(b) if b else a) + 1):
        if (f, ln) not in seen: seen.append((f, ln))
for m in re.finditer(r"`(\d\d-[a-z0-9.-]+):\d+`, `:(\d+)`", doc):
    k = (m.group(1), int(m.group(2)))
    if k not in seen: seen.append(k)
for f, ln in sorted(seen):
    lines = (fx / f"{f}.jsonl").read_text().splitlines()
    if ln > len(lines):
        print(f"{f}:{ln:<3} MISSING"); continue
    d = json.loads(lines[ln - 1])
    if "snapshot" in d: desc = "SNAPSHOT"
    elif "note" in d: desc = "NOTE " + d["note"]
    else:
        parts = []
        for e in d["batch"]:
            s = e["type"]
            if "entry" in e: s += f"({e['entry']['kind']})"
            if e["type"] == "message_start": s += f"({e['message']['role']})"
            if e["type"] == "message_update": s += "[" + ",".join(c["type"] for c in e["changes"]) + "]"
            if e["type"] == "tool_execution_update": s += "{" + ",".join(k for k in ("output", "details") if k in e) + "}"
            parts.append(s)
        desc = " ".join(parts)
    print(f"{f}:{ln:<3} {desc[:140]}")
