#!/usr/bin/env python3
"""로컬 시험용 가짜 Slack API.

진짜 봇 토큰 없이 출시 소식 흐름(채널 등록, 출시하고 알리기, 나중에 보내기)을
눌러 보려고 둔다. 서버의 SLACK_API_BASE_URL 을 여기로 가리킨다.

    python3 scripts/fake-slack.py            # http://127.0.0.1:8090/api
    SLACK_BOT_TOKEN=xoxb-fake
    SLACK_API_BASE_URL=http://127.0.0.1:8090/api

- 채널은 #releases, #team-a 두 개다. 봇과 사람이 모두 들어가 있다
- #no-bot 은 봇이 없는 채널이다. 등록이 막히는 것을 볼 때 쓴다
- 어떤 이메일이든 같은 사람(U1)으로 찾는다
- chat.postMessage 로 온 글은 보내지 않고 여기 출력에 찍는다

표준 라이브러리만 쓴다. 이 기계(127.0.0.1)에서만 받는다.
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

CHANNELS = [
    {"id": "C0000000001", "name": "releases", "is_member": True},
    {"id": "C0000000002", "name": "team-a", "is_member": True},
    {"id": "C0000000003", "name": "no-bot", "is_member": False},
]


def answer(method, query, body):
    if method == "auth.test":
        return {"ok": True, "user": "alley-bot"}
    if method == "conversations.list":
        return {"ok": True, "channels": CHANNELS, "response_metadata": {"next_cursor": ""}}
    if method == "conversations.info":
        requested = query.get("channel", [""])[0]
        for channel in CHANNELS:
            if channel["id"] == requested:
                return {"ok": True, "channel": channel}
        return {"ok": False, "error": "channel_not_found"}
    if method == "conversations.members":
        return {"ok": True, "members": ["U1"], "response_metadata": {"next_cursor": ""}}
    if method == "users.lookupByEmail":
        return {"ok": True, "user": {"id": "U1"}}
    if method == "chat.postMessage":
        payload = json.loads(body or b"{}")
        print("\n--- chat.postMessage → %s" % payload.get("channel"), flush=True)
        print(payload.get("text", ""), flush=True)
        for block in payload.get("blocks", []):
            text = (block.get("text") or {}).get("text")
            if text:
                print(text, flush=True)
        return {"ok": True, "channel": payload.get("channel"), "ts": "1.0"}
    return {"ok": False, "error": "unknown_method"}


class Handler(BaseHTTPRequestHandler):
    def handle_any(self):
        url = urlparse(self.path)
        method = url.path.rsplit("/", 1)[-1]
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        data = json.dumps(answer(method, parse_qs(url.query), body)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = handle_any
    do_POST = handle_any

    def log_message(self, format, *args):
        sys.stderr.write("[fake-slack] %s\n" % (format % args))


if __name__ == "__main__":
    port = int(os.environ.get("FAKE_SLACK_PORT", "8090"))
    print("가짜 Slack: http://127.0.0.1:%d/api" % port, flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
