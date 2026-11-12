#!/usr/bin/env python3
"""Hermes Watch bridge: plain HTTP in front of the dashboard's JSON-RPC websocket.

Why: watchOS only allows HTTP data tasks on a real watch (Apple TN3135 blocks websockets outside audio streaming),
and the Hermes dashboard only accepts prompts on /api/ws. This process keeps ONE websocket to the local dashboard and
exposes two calls:
  POST /rpc     {"method": ..., "params": {...}}            -> {"result": ...} or {"error": ...}
  GET  /events  ?session_id=...&after=<seq>&wait=<seconds>  -> {"events": [{seq, type, payload}], "last": <seq>}
It runs outside Hermes (nothing in the harness changes), listens on loopback only, and asks for the same bearer token
as the dashboard.  Run:  watch_bridge.py --upstream wss://HOST:PORT/api/ws --token TOKEN [--port 9120]
"""
import argparse, asyncio, collections, json, os, ssl, time

import certifi, uvicorn, websockets
from fastapi import FastAPI, Header, HTTPException, Query
from pydantic import BaseModel

# The dashboard websocket, at the address the phone app uses (a dashboard may refuse a bare loopback websocket).
UPSTREAM = os.environ.get("HERMES_WS", "")
TOKEN = os.environ.get("HERMES_TOKEN", "")
ALLOWED = {"session.list", "session.create", "session.resume", "session.history", "session.interrupt", "session.most_recent",
           "prompt.submit", "model.options", "session.mutate", "approval.respond", "clarify.respond"}
# Answers a wearer may give to the dashboard's questions (events approval.request / clarify.request).
# "always" stays on a bigger screen: a permanent allow-list entry is not a decision for a wrist.
WATCH_CHOICES = {"once", "session", "deny"}
MAX_ANSWER = 2000
KEEP = 4000          # events kept per session
IDLE_DROP = 6 * 3600  # forget a session's buffer after this long without traffic
COALESCE = 0.25      # seconds to let a few more events arrive before answering a poll


def note(*parts):
    """One diagnostic line: which call, for which conversation (first characters of its id). Never a text or a token."""
    print(time.strftime("%H:%M:%S"), " ", *parts, flush=True)


class Upstream:
    def __init__(self):
        self.ws = None
        self.n = 0
        self.pending: dict[str, asyncio.Future] = {}
        self.buffers: dict[str, collections.deque] = {}
        self.seq: dict[str, int] = {}
        self.touched: dict[str, float] = {}
        self.cond = asyncio.Condition()
        self.resumed: set[str] = set()
        self.lock = asyncio.Lock()
        self.reader = None

    async def ensure(self):
        async with self.lock:
            if self.ws is not None and self.reader is not None and not self.reader.done():
                return
            tls = ssl.create_default_context(cafile=certifi.where()) if UPSTREAM.startswith("wss") else None
            self.ws = await websockets.connect(f"{UPSTREAM}?token={TOKEN}", max_size=None, open_timeout=15, ping_interval=20, ssl=tls)
            self.resumed.clear()                       # a new connection has no subscriptions
            self.reader = asyncio.create_task(self._read(self.ws))
        await self.call("client.capabilities", {"server_requests": False}, ensure=False)

    async def _read(self, ws):
        try:
            async for raw in ws:
                f = json.loads(raw)
                fid = f.get("id")
                if fid in self.pending and ("result" in f or "error" in f):
                    fut = self.pending.pop(fid)
                    if not fut.done():
                        fut.set_result(f)
                elif f.get("method") == "event":
                    p = f.get("params") or {}
                    await self._push(p.get("session_id") or "", p.get("type") or "", p.get("payload") or {})
        except Exception:
            pass
        finally:
            for fut in self.pending.values():
                if not fut.done():
                    fut.set_exception(ConnectionError("dashboard connection closed"))
            self.pending.clear()

    async def _push(self, sid, typ, payload):
        if not sid:
            return
        async with self.cond:
            n = self.seq[sid] = self.seq.get(sid, 0) + 1
            self.buffers.setdefault(sid, collections.deque(maxlen=KEEP)).append({"seq": n, "type": typ, "payload": payload})
            self.touched[sid] = time.time()
            self.cond.notify_all()

    async def call(self, method, params, timeout=60, ensure=True):
        if ensure:
            await self.ensure()
        self.n += 1
        fid = f"b{self.n}"
        fut = self.pending[fid] = asyncio.get_running_loop().create_future()
        assert self.ws is not None
        await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": fid, "method": method, "params": params}))
        try:
            return await asyncio.wait_for(fut, timeout)
        finally:
            self.pending.pop(fid, None)

    async def subscribe(self, sid):
        """Events of a session only reach the connection that created or resumed it."""
        if sid and sid not in self.resumed:
            r = await self.call("session.resume", {"session_id": sid})
            if "error" not in r:
                self.resumed.add(sid)
            return r
        return None

    async def events(self, sid, after, wait):
        deadline = time.time() + wait
        fresh = lambda: [e for e in self.buffers.get(sid, ()) if e["seq"] > after]
        async with self.cond:
            while not fresh():
                left = deadline - time.time()
                if left <= 0:
                    return []
                try:
                    await asyncio.wait_for(self.cond.wait(), left)
                except asyncio.TimeoutError:
                    return []
        await asyncio.sleep(COALESCE)   # tokens come one event at a time: answer with a small batch, fewer round trips for the watch
        return fresh()

    def sweep(self):
        now = time.time()
        for sid in [s for s, t in self.touched.items() if now - t > IDLE_DROP]:
            for d in (self.buffers, self.seq, self.touched):
                d.pop(sid, None)


up = Upstream()
app = FastAPI(title="Hermes Watch bridge", docs_url=None, redoc_url=None)


@app.middleware("http")
async def access_log(request, call_next):
    """One line per request (never the token): which device called, through which path, and the answer."""
    resp = await call_next(request)
    who = request.headers.get("x-forwarded-for") or (request.client.host if request.client else "?")
    agent = (request.headers.get("user-agent") or "")[:40]
    print(time.strftime("%H:%M:%S"), request.method, request.url.path, resp.status_code, "from", who, "|", agent, flush=True)
    return resp


class Rpc(BaseModel):
    method: str
    params: dict = {}


def check(auth):
    if auth != f"Bearer {TOKEN}":
        raise HTTPException(401, "bad token")


@app.get("/health")
async def health():
    try:
        await up.ensure()
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "error": str(e)[:200]}


@app.post("/rpc")
async def rpc(body: Rpc, authorization: str = Header(default="")):
    check(authorization)
    note("rpc", body.method, str(body.params.get("session_id") or "")[:14], str(body.params.get("operation") or ""))
    if body.method not in ALLOWED:
        raise HTTPException(400, f"method not allowed: {body.method}")
    if body.method == "session.mutate" and body.params.get("operation") != "model":
        raise HTTPException(400, "session.mutate is limited to the model operation")   # no delete, rewind or reset from the wrist
    if body.method == "approval.respond" and body.params.get("choice") not in WATCH_CHOICES:
        raise HTTPException(400, "approval choice must be once, session or deny")
    if body.method == "clarify.respond" and not (isinstance(body.params.get("answer"), str) and len(body.params["answer"]) <= MAX_ANSWER):
        raise HTTPException(400, "clarify answer must be a short text")
    try:
        sid = body.params.get("session_id")
        if body.method in ("prompt.submit", "session.history", "session.mutate", "session.interrupt",
                           "approval.respond", "clarify.respond") and sid:
            await up.subscribe(sid)
        f = await up.call(body.method, body.params)
        if body.method in ("session.create", "session.resume") and "result" in f:
            new = (f["result"] or {}).get("session_id") or sid
            if new:
                up.resumed.add(new)
        up.sweep()
        return {"result": f["result"]} if "result" in f else {"error": f.get("error")}
    except HTTPException:
        raise
    except Exception as e:  # dashboard down, refused, slow: one clear answer for the watch
        raise HTTPException(502, f"dashboard unreachable: {type(e).__name__}")


@app.get("/events")
async def events(session_id: str, after: int = 0, wait: float = Query(default=20, le=50), authorization: str = Header(default="")):
    check(authorization)
    try:
        await up.ensure()
        await up.subscribe(session_id)
    except HTTPException:
        raise
    except Exception as e:  # dashboard down, refused, slow: one clear answer for the watch
        raise HTTPException(502, f"dashboard unreachable: {type(e).__name__}")
    ev = await up.events(session_id, after, wait)
    note("events", session_id[:14], f"after={after}", f"sent={len(ev)}")
    return {"events": ev, "last": ev[-1]["seq"] if ev else after}


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="HTTP bridge between a watch and the Hermes dashboard websocket.")
    ap.add_argument("--upstream", default=UPSTREAM, help="dashboard websocket, as the phone app reaches it: wss://HOST:PORT/api/ws (env HERMES_WS)")
    ap.add_argument("--token", default=TOKEN, help="dashboard token; the watch must send the same one (env HERMES_TOKEN)")
    ap.add_argument("--host", default="127.0.0.1", help="listen address; keep loopback and put an HTTPS reverse proxy in front")
    ap.add_argument("--port", type=int, default=9120)
    a = ap.parse_args()
    if not a.upstream or not a.token:
        ap.error("--upstream and --token are required (or HERMES_WS and HERMES_TOKEN)")
    UPSTREAM, TOKEN = a.upstream, a.token
    uvicorn.run(app, host=a.host, port=a.port, log_level="warning")
