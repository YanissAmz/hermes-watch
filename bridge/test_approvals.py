#!/usr/bin/env python3
"""Answers to the dashboard's questions through the bridge, against a stand-in dashboard (no Hermes needed).

The dashboard announces a question with an `approval.request` or `clarify.request` event and takes the answer with
`approval.respond` / `clarify.respond`. Checks: the events reach the watch unchanged, an approval choice the watch may
give (once, session, deny) is forwarded exactly as sent, "always" and unknown choices are refused by the bridge without
reaching the dashboard, a clarify answer is forwarded, an empty or oversized one is refused.
Run:  python bridge/test_approvals.py
"""
import asyncio, json, os, socket, subprocess, sys, urllib.error, urllib.request

import websockets

HERE = os.path.dirname(os.path.abspath(__file__))
TOKEN = "test-token"
calls: list[tuple[str, dict]] = []      # what the fake dashboard was asked
PROMPT = {"kind": "approval", "prompt_id": "p1", "execution_generation": 2, "command": "rm -rf build",
          "description": "recursive delete", "choices": ["once", "deny", "session", "always"], "timeout_s": 60}
QUESTION = {"kind": "clarify", "prompt_id": "c1", "execution_generation": 2, "question": "Which branch?",
            "choices": ["main", "dev"], "multi_select": False}


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


async def dashboard(ws):
    try:
        async for raw in ws:
            f = json.loads(raw)
            method, params = f.get("method"), f.get("params") or {}
            calls.append((method, params))
            result = {"status": "resolved", "prompt_id": params.get("prompt_id")} if method in ("approval.respond", "clarify.respond") else \
                {"session_id": params.get("session_id") or "s1", "running": True, "status": "queued"}
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": f.get("id"), "result": result}))
            if method == "prompt.submit":
                for typ, payload in (("approval.request", PROMPT), ("clarify.request", QUESTION)):
                    await ws.send(json.dumps({"jsonrpc": "2.0", "method": "event",
                                              "params": {"type": typ, "session_id": "s1", "payload": payload}}))
    except websockets.ConnectionClosed:
        pass                                   # the bridge stopped at the end of the test


def http(base, method, path, body=None):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None, method=method,
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {TOKEN}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, {}


async def main():
    up_port, br_port = free_port(), free_port()
    server = await websockets.serve(dashboard, "127.0.0.1", up_port)
    bridge = subprocess.Popen([sys.executable, os.path.join(HERE, "watch_bridge.py"), "--upstream", f"ws://127.0.0.1:{up_port}/api/ws",
                               "--token", TOKEN, "--port", str(br_port)], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    base, ok = f"http://127.0.0.1:{br_port}", True

    def check(name, cond):
        nonlocal ok
        ok &= bool(cond)
        print(("PASS " if cond else "FAIL ") + name)

    try:
        for _ in range(50):
            try:
                if (await asyncio.to_thread(http, base, "GET", "/health"))[0] == 200:
                    break
            except Exception:
                pass
            await asyncio.sleep(0.2)
        rpc = lambda m, p: asyncio.to_thread(http, base, "POST", "/rpc", {"method": m, "params": p})
        await rpc("prompt.submit", {"session_id": "s1", "text": "clean the build", "submission_id": "x"})
        await asyncio.sleep(0.4)
        _, ev = await asyncio.to_thread(http, base, "GET", "/events?session_id=s1&after=0&wait=3")
        by_type = {e["type"]: e["payload"] for e in ev["events"]}
        check("approval.request reaches the watch unchanged", by_type.get("approval.request") == PROMPT)
        check("clarify.request reaches the watch unchanged", by_type.get("clarify.request") == QUESTION)

        answer = {"session_id": "s1", "execution_generation": 2, "prompt_id": "p1"}
        before = len(calls)
        for bad in ("always", "yes", None):
            status, _ = await rpc("approval.respond", {**answer, "choice": bad} if bad else answer)
            check(f"approval choice {bad!r} refused by the bridge", status == 400)
        check("refused choices never reach the dashboard", len(calls) == before)
        status, r = await rpc("approval.respond", {**answer, "choice": "session"})
        sent = [p for m, p in calls if m == "approval.respond"]
        check("a watch choice is forwarded exactly", status == 200 and sent == [{**answer, "choice": "session"}]
              and r.get("result", {}).get("status") == "resolved")

        clarify = {"session_id": "s1", "execution_generation": 2, "prompt_id": "c1"}
        for name, bad in (("missing", None), ("oversized", "x" * 2001), ("not text", 3)):
            status, _ = await rpc("clarify.respond", {**clarify, "answer": bad} if bad is not None else clarify)
            check(f"clarify answer {name} refused", status == 400)
        status, _ = await rpc("clarify.respond", {**clarify, "answer": "dev"})
        check("a clarify answer is forwarded", status == 200 and [p for m, p in calls if m == "clarify.respond"] == [{**clarify, "answer": "dev"}])
    finally:
        bridge.terminate(); bridge.wait(timeout=10)
        server.close(); await server.wait_closed()
    print("ALL PASS" if ok else "SOME FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
