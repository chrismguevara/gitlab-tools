#!/usr/bin/env python3
"""Minimal OpenAI-compatible chat completions mock for exercising opencode offline.

Behaviour is driven by MOCK_SCRIPT (JSON file): a list of "turns". Each request pops
the next turn. A turn is either {"text": "..."} or
{"tool": "bash", "args": {"command": "echo hi", "description": "say hi"}}.
Every request is appended to MOCK_LOG as JSON for inspection.
"""
import json, os, sys, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT = os.environ.get("MOCK_SCRIPT", "script.json")
LOG = os.environ.get("MOCK_LOG", "requests.log")
PORT = int(os.environ.get("MOCK_PORT", "8787"))
STATE = {"i": 0}

def load_turns():
    with open(SCRIPT) as f:
        return json.load(f)

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def do_GET(self):
        if self.path.endswith("/models"):
            body = json.dumps({"object": "list", "data": [{"id": "scripted", "object": "model"}]}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(n)
        try:
            req = json.loads(raw)
        except Exception:
            req = {"_raw": raw.decode(errors="replace")}
        with open(LOG, "a") as f:
            f.write(json.dumps({"path": self.path, "req": req}) + "\n")
        sys_txt = " ".join(str(m.get("content")) for m in req.get("messages", []) if m.get("role") == "system")
        if "You are a title generator" in sys_txt:
            turn = {"text": "Mock Title"}
        else:
            turns = load_turns()
            turn = turns[min(STATE["i"], len(turns) - 1)]
            STATE["i"] += 1
        stream = bool(req.get("stream"))
        cid = "chatcmpl-" + uuid.uuid4().hex[:12]
        now = int(time.time())
        model = req.get("model", "scripted")
        if "tool" in turn:
            tc = {"id": "call_" + uuid.uuid4().hex[:8], "type": "function",
                  "function": {"name": turn["tool"], "arguments": json.dumps(turn.get("args", {}))}}
            finish = "tool_calls"
        else:
            finish = "stop"
        usage = {"prompt_tokens": 100, "completion_tokens": 20, "total_tokens": 120}
        if stream:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream"); self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            def chunk(delta, fr=None):
                d = {"id": cid, "object": "chat.completion.chunk", "created": now, "model": model,
                     "choices": [{"index": 0, "delta": delta, "finish_reason": fr}]}
                self.wfile.write(f"data: {json.dumps(d)}\n\n".encode()); self.wfile.flush()
            chunk({"role": "assistant", "content": ""})
            if "tool" in turn:
                chunk({"tool_calls": [{"index": 0, "id": tc["id"], "type": "function",
                                       "function": {"name": tc["function"]["name"], "arguments": ""}}]})
                chunk({"tool_calls": [{"index": 0, "function": {"arguments": tc["function"]["arguments"]}}]})
            else:
                for piece in turn["text"].split(" "):
                    chunk({"content": piece + " "})
            chunk({}, finish)
            last = {"id": cid, "object": "chat.completion.chunk", "created": now, "model": model, "choices": [], "usage": usage}
            self.wfile.write(f"data: {json.dumps(last)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()
        else:
            msg = {"role": "assistant", "content": None if "tool" in turn else turn["text"]}
            if "tool" in turn:
                msg["tool_calls"] = [tc]
            body = json.dumps({"id": cid, "object": "chat.completion", "created": now, "model": model,
                               "choices": [{"index": 0, "message": msg, "finish_reason": finish}], "usage": usage}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
