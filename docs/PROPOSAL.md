# Proposal: an HTTP path for clients that cannot open a WebSocket

Draft of an issue for NousResearch/hermes-agent.

## The problem

The dashboard accepts prompts and streams replies only over the JSON-RPC WebSocket at `/api/ws`. One class of client
cannot use it: an Apple Watch app.

Apple's [TN3135](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos) splits
watchOS networking in two. HTTP and HTTPS through `URLSession` are open to every app. Everything that runs a
connection directly, `URLSessionWebSocketTask` included (revision of 2021-05-14), is low-level networking, and
watchOS blocks it unless the app is streaming audio, running a CallKit call, or pairing with a tvOS app. The note adds
that the simulator always allows it, so a watch client built on the WebSocket looks fine until it meets a real watch.

Checked on hardware (Apple Watch Series 11, watchOS 27.0.1, 12 Nov 2026), with a debug probe in the app that opens the
dashboard WebSocket with `URLSessionWebSocketTask` and sends a ping:

| Where | Result |
|---|---|
| watchOS simulator | opened and answered the ping in 0.1 s |
| real watch, same build, same address | failed after 0.2 s: `NSURLErrorDomain -1009` (not connected to the internet) |

In the same launch on the real watch, the app's HTTPS calls to the bridge went through (HTTP 200). The watch was
online; only the WebSocket was refused. Reproduce with `HERMES_WS_PROBE=wss://...` (see `App/Sources/HermesWatchApp.swift`).

Other constrained clients are in the same position for different reasons: shortcuts and automations, widgets, and
environments where only request/response HTTP gets through a proxy.

## What works today

[Hermes Watch](../README.md) puts a small bridge in front of the dashboard. The watch only does:

```
POST /rpc     {"method": "...", "params": {...}}                 -> {"result": ...} | {"error": ...}
GET  /events  ?session_id=...&after=<seq>&wait=<seconds>         -> {"events": [{seq, type, payload}], "last": <seq>}
```

- `/rpc` forwards one JSON-RPC call over a WebSocket the bridge keeps open, and returns its result.
- `/events` is a long poll. The bridge numbers the events of each session as they arrive, keeps a bounded buffer, and
  answers with everything after the client's last sequence number, or waits up to `wait` seconds. A client that was
  away asks again with its last number and misses nothing that is still in the buffer.
- Both ask for the dashboard's bearer token.

The app runs on a real Apple Watch Series 11 (watchOS 27.0.1); its calls reach the dashboard through the paired
iPhone. Done on the watch itself: conversation list, new conversation, a dictated message, and the reply shown on the
screen (one turn: 63 events in 5 polls, about 4 seconds from send to the end of the reply), the model switch for one
conversation (a model picked in the list answered the next two turns), Stop (the turn ended as interrupted, under a
second after the tap reached the bridge), and an approval answered from the wrist (the command ran once allowed).

One run of that test, for scale: a one-word reply produced 18 events, delivered in 2 polls; a long turn that was
interrupted ended as cancelled about 2 seconds after it was submitted. The bridge waits 250 ms before answering a poll
so that a burst of deltas travels in one response.

## The proposal

Serve the same two endpoints from the dashboard itself, next to `/api/ws`, behind the same authentication:

- `POST /api/rpc`: one JSON-RPC request in, one response out, same methods and same errors as the WebSocket.
- `GET /api/events`: long poll of a session's events by sequence number.

What it takes on the server: a per-session sequence number and a bounded replay buffer for events (the WebSocket path
can keep ignoring both), and the long-poll handler. No change to the protocol's methods or payloads.

What it gives: a watch app, or any HTTP-only client, talks to a stock Hermes with nothing extra to run.

## Open questions

- Should the HTTP path expose every method, or a reduced set? The bridge allows only what a small client needs and
  refuses the rest (delete, config changes), which felt right for a device that is easy to lose.
- Server-sent events would stream better than a long poll and are plain HTTP, so watchOS allows them in principle.
  I have not tried them on a watch. The long poll was the safe choice: it is one ordinary request at a time.
- Approvals and clarifications already fit this path: they arrive as events (`approval.request`, `clarify.request`) and
  are answered with a method (`approval.respond`, `clarify.respond`), so the long poll carries them unchanged. The
  bridge only narrows the choices a watch may give: once, for this conversation, or deny, never "always".

I can turn the bridge into a pull request against the dashboard if this direction suits you.
