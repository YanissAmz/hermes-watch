#!/usr/bin/env python3
"""End-to-end test of the watch bridge over plain HTTP, as the watch will use it:
auth refused, forbidden method refused, lists, create, submit, long-poll events to message.complete, history.
Prints PASS/FAIL per check and exits non-zero on any failure. Usage: test_bridge.py [base_url]"""
import json, os, subprocess, sys, time, urllib.error, urllib.request, uuid

B = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:9120"
TOKEN = os.environ.get("HERMES_TOKEN", "")
fails = []


def http(path, body=None, token: "str | None" = TOKEN, timeout=60) -> "tuple[int, dict]":
    req = urllib.request.Request(B + path, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json", **({"Authorization": f"Bearer {token}"} if token else {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, {}


def rpc(method, **params):
    return http("/rpc", {"method": method, "params": params})


def check(name, ok, detail=""):
    print(("PASS" if ok else "FAIL"), name, detail)
    if not ok:
        fails.append(name)


check("no token -> 401", http("/rpc", {"method": "session.list", "params": {}}, token=None)[0] == 401)
check("session.delete refused -> 400", rpc("session.delete", session_id="x")[0] == 400)
check("session.mutate other than model refused -> 400", rpc("session.mutate", session_id="x", operation="delete", payload={})[0] == 400)
check("config.set refused -> 400", rpc("config.set", key="fast", value="on")[0] == 400)
c, live = rpc("session.list")
check("live list", c == 200 and "sessions" in (live or {}).get("result", {}), f"{len(live['result']['sessions'])} live" if c == 200 else str(c))
c, st = rpc("session.list", scope="stored", limit=5)
check("stored list", c == 200 and len(st["result"]["sessions"]) > 0, str([s["title"][:25] for s in st["result"]["sessions"][:3]]) if c == 200 else str(c))
c, cr = rpc("session.create", cwd=os.path.expanduser("~"))
sid = ((cr or {}).get("result") or {}).get("session_id")
check("create", c == 200 and bool(sid), (sid or "")[:20])
c, mo = rpc("model.options", session_id=sid)
provs = ((mo or {}).get("result") or {}).get("providers") or []
check("model options", c == 200 and len(provs) > 0, str([(p["slug"], p["is_current"], len(p["models"])) for p in provs][:5]))
# Model pick: the revision-fenced session.mutate, for this conversation only.
before = (mo["result"]["model"], mo["result"]["provider"])
target = next(((m, p["slug"]) for p in provs for m in p["models"] if (m, p["slug"]) != before and p.get("authenticated", True)), None)
if target:
    snap = rpc("session.resume", session_id=sid)[1]["result"]
    c, mu = rpc("session.mutate", session_id=sid, request_id=uuid.uuid4().hex, operation="model", payload={"model": target[0], "provider": target[1]},
                expected_revision=snap["revision"], expected_generation=snap["execution_generation"])
    now = rpc("model.options", session_id=sid)[1]["result"]
    check("model switch for this conversation", c == 200 and (now["model"], now["provider"]) == target, f"{before} -> {(now['model'], now['provider'])} reply {json.dumps(mu)[:90]}")
    other = rpc("session.create")[1]["result"]["session_id"]
    dflt = rpc("model.options", session_id=other)[1]["result"]
    check("default model untouched", (dflt["model"], dflt["provider"]) == before, str((dflt["model"], dflt["provider"])))
    subprocess.run(["hermes", "sessions", "delete", other, "--yes"], capture_output=True)
    snap = rpc("session.resume", session_id=sid)[1]["result"]
    rpc("session.mutate", session_id=sid, request_id=uuid.uuid4().hex, operation="model", payload={"model": before[0], "provider": before[1]},
        expected_revision=snap["revision"], expected_generation=snap["execution_generation"])
c, sub = rpc("prompt.submit", session_id=sid, text="Reply with this single word only: wrist", submission_id=uuid.uuid4().hex)
check("submit", c == 200 and ((sub or {}).get("result") or {}).get("status") in ("queued", "accepted", "running"), json.dumps(sub)[:90])
after, text, done, kinds, polls, t0 = 0, "", False, [], 0, time.time()
while time.time() - t0 < 120:
    polls += 1
    c, ev = http(f"/events?session_id={sid}&after={after}&wait=10")
    if c != 200:
        check("events poll", False, str(c)); break
    for e in ev["events"]:
        kinds.append(e["type"])
        if e["type"] == "message.delta":
            text += e["payload"].get("text") or ""
        done = done or e["type"] == "message.complete"
    after = ev["last"]
    if done:
        break
check("events reach message.complete", done, f"{len(kinds)} events in {polls} polls, {time.time() - t0:.0f}s, kinds {sorted(set(kinds))}")
check("streamed text has the word", "wrist" in text.lower(), repr(text[:60]))
c, ev = http(f"/events?session_id={sid}&after={after}&wait=1")
check("no replay after last seq", c == 200 and ev["events"] == [] or all(e["seq"] > after for e in ev["events"]))
c, hi = rpc("session.history", session_id=sid)
msgs = ((hi or {}).get("result") or {}).get("messages") or []
check("history has user + assistant", [m["role"] for m in msgs][:2] == ["user", "assistant"], str([(m["role"], m["text"][:30]) for m in msgs]))
# Stop a running turn: session.interrupt needs the turn's generation.
rpc("prompt.submit", session_id=sid, text="Write the numbers from 1 to 400, one per line, nothing else.", submission_id=uuid.uuid4().hex)
gen, t1, outcome, n = None, time.time(), None, 0
while time.time() - t1 < 60 and outcome is None:
    c, ev = http(f"/events?session_id={sid}&after={after}&wait=5")
    after = ev.get("last", after)
    for e in ev.get("events", []):
        n += e["type"] == "message.delta"
        if e["type"] == "message.complete":
            outcome = e["payload"].get("outcome")
    if gen is None and n >= 1:
        snap = rpc("session.resume", session_id=sid)[1]["result"]
        gen = snap["execution_generation"]
        ci, it = rpc("session.interrupt", session_id=sid, execution_generation=gen)
        check("interrupt accepted", ci == 200 and "error" not in it, json.dumps(it)[:100])
check("interrupted turn ends as interrupted", outcome is not None and outcome != "completed", f"outcome={outcome} after {time.time() - t1:.0f}s")
if sid:
    out = subprocess.run(["hermes", "sessions", "delete", sid, "--yes"], capture_output=True, text=True).stdout.strip()[-40:]
    print("cleanup:", out)
print("RESULT:", "ALL PASS" if not fails else f"{len(fails)} FAILED: {fails}")
sys.exit(1 if fails else 0)
