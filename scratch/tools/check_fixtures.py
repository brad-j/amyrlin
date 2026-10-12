# Asserts that each fixture still shows the behaviour its scenario is about. Usage: python3 -I check_fixtures.py <dir>
import json, pathlib, sys

def load(path):
    lines = [json.loads(l) for l in path.read_text().splitlines()]
    events = [e for d in lines for e in d.get("batch", [])]
    return lines, events

def types(events): return [e["type"] for e in events]
def subs(events, status): return [e["record"] for e in events if e["type"] == "submission" and e["record"]["status"] == status]
def results(events): return [m for e in events if e["type"] == "message_end" and e["entry"]["kind"] == "pi.tool-result" for m in e["entry"]["model"]]
def assistant_stops(events): return [m.get("stopReason") for e in events if e["type"] == "message_end" for m in e["entry"].get("model", []) if m["role"] == "assistant"]

checks = {
    "01-plain-answer": lambda L, E: "thinking_delta" in json.dumps(E) and assistant_stops(E) == ["stop"],
    "02-tool-round": lambda L, E: types(E).count("tool_execution_start") == 1 and len(results(E)) == 1,
    "03-parallel-tools": lambda L, E: types(E).count("tool_execution_start") == 3 and len(results(E)) == 3,
    "04-steer-during-tools": lambda L, E: any(e["type"] == "inbox_update" and any(i["mode"] == "steer" for i in e["items"]) for e in E)
        and any(e["type"] == "run_end" and len(e["inputs"]) == 2 for e in E),
    "05-follow-up-while-busy": lambda L, E: any(e["type"] == "inbox_update" and any(i["mode"] == "followUp" for i in e["items"]) for e in E)
        and types(E).count("run_start") == 2,
    "06-abort-mid-generation": lambda L, E: "aborted" in assistant_stops(E) and any(r.get("reason") == "aborted" for r in subs(E, "unanswered")),
    "07-abort-mid-tool": lambda L, E: any(r["isError"] for r in results(E)) and "aborted" in json.dumps(results(E)),
    "08-blocked-tool": lambda L, E: "blocked" in json.dumps(results(E)) and types(E).count("tool_execution_start") == 1,
    "09-manual-compaction": lambda L, E: "compaction_start" in types(E) and "pi.compaction" in json.dumps(E),
    "10-late-join": lambda L, E: any(s["status"] == "running" and s.get("output") for s in L[0]["snapshot"]["tools"]),
    "10-late-join.mid-answer": lambda L, E: L[0]["snapshot"].get("generation", {}).get("message") is not None,
    "10-late-join.full": lambda L, E: L[0]["snapshot"]["entries"] == [] and "run_end" in types(E),
    "11-crash-and-resume": lambda L, E: any("SIGKILL" in d.get("note", "") for d in L)
        and sum(1 for d in L if "snapshot" in d) == 2 and "interrupted" in json.dumps(results(E)) and subs(E, "done"),
    "12-approval-hook": lambda L, E: any("hook entered" in d.get("note", "") for d in L) and len(results(E)) == 1,
    "15-approval-crash-resume": lambda L, E: len({(d.get("data") or {}).get("pid") for d in L if "hook entered" in d.get("note", "")}) == 2
        and "tool_execution_start" in types(E) and subs(E, "done"),
    "16-approval-abort": lambda L, E: any(d.get("note") == "hook wait ended" and d["data"]["by"] == "abort signal" for d in L)
        and "aborted" in json.dumps(results(E)) and any(r.get("reason") == "aborted" for r in subs(E, "unanswered")),
    "13-configure-and-reset": lambda L, E: types(E).count("agent_changed") == 2 and "pi.reset" in json.dumps(E),
    "14-overflow-snapshot": lambda L, E: "snapshot" in types(E),
}

root = pathlib.Path(sys.argv[1]); failed = 0
for name, check in checks.items():
    path = root / f"{name}.jsonl"
    lines, events = load(path)
    ok = check(lines, events) and lines[-1].get("end") is not None
    failed += not ok
    print(("ok  " if ok else "FAIL"), name)
extra = {p.stem for p in root.glob("*.jsonl")} - set(checks)
if extra: print("unchecked:", sorted(extra)); failed += 1
sys.exit(1 if failed else 0)
