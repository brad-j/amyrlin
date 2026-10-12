# Prints one line per fixture record: time, kind, and the interesting parts of each event.
import json, sys

def ev(e):
    t = e["type"]
    if t == "message_start":
        m = e["message"]; return f"message_start({m['role']}{'/'+m.get('stopReason','') if m['role']=='assistant' else ''})"
    if t == "message_end":
        en = e["entry"]; roles = ",".join(m["role"] for m in en.get("model", []))
        extra = ""
        for m in en.get("model", []):
            if m["role"] == "assistant": extra = "/" + m.get("stopReason", "")
            if m["role"] == "toolResult": extra = f"/{m.get('toolCallId')} err={m.get('isError')}"
        return f"message_end({en['kind']}#{en['id']} {roles}{extra})"
    if t == "message_update":
        return "message_update[" + ",".join(c["type"] + (f"@{c.get('contentIndex')}" if 'contentIndex' in c else '') for c in e["changes"]) + "]"
    if t.startswith("tool_execution"):
        rest = {k: v for k, v in e.items() if k not in ("type", "toolName", "toolCallId")}
        if "entry" in rest: rest["entry"] = f"{rest['entry']['kind']}#{rest['entry']['id']}"
        return f"{t}({e['toolCallId']} {json.dumps(rest)[:120]})"
    if t == "submission":
        r = e["record"]; return f"submission(#{r['id']} {r.get('requestId')} {r['status']} {r.get('reason','')} {r.get('mode','')})"
    if t == "entry_appended":
        return f"entry_appended({e['entry']['kind']}#{e['entry']['id']})"
    if t == "snapshot": return "SNAPSHOT(mid-stream)"
    rest = {k: v for k, v in e.items() if k != "type"}
    return f"{t}{json.dumps(rest)[:140] if rest else ''}"

for l in open(sys.argv[1]):
    d = json.loads(l)
    if "batch" in d: print(f"{d['t']:>5} B  " + "  ".join(ev(e) for e in d["batch"]))
    elif "snapshot" in d:
        s = d["snapshot"]
        print(f"{d['t']:>5} S  entries={[x['kind']+'#'+str(x['id']) for x in s['entries']]} run={s.get('run')} gen={'msg' if s.get('generation',{}).get('message') else s.get('generation')} tools={[(x['callId'],x['status'],repr(x.get('output',''))) for x in s['tools']]} inbox={s['inbox']} compactions={s['compactions']}")
    elif "note" in d: print(f"{d['t']:>5} N  {d['note']} {json.dumps(d.get('data',''))}")
    else: print(f"{d['t']:>5} ?  {json.dumps(d)[:200]}")
