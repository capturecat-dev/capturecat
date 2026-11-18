#!/usr/bin/env python3
"""A local stand-in for the CaptureCat API, for testing the iOS client end to
end without touching production storage (`wrangler dev` binds R2 to the REAL
bucket, so the real local API is not safe for upload tests).

It follows the contracts of apps/api/src/routes/{cloud-projects,desktop,
devices,video}.ts closely enough to exercise every client path:

  /api/desktop/authorize   validates PKCE params + loopback redirect, then
                           "consents" immediately: 302 → redirect_uri?code&state
  /api/desktop/token       S256(verifier) must equal the challenge; one use
  /api/me, /api/videos, /api/video/:id/comments (GET/POST)
  /api/cloud-projects      list / stage / finalize (202 once, then 200) / get /
                           save with If-Match (409 + current document) / delete
  /upload/<sha>            presigned-PUT stand-in: checks Content-Type, size and
                           SHA-256 exactly like the real finalize does
  /files/<sha>             presigned-GET stand-in with Range support (AVPlayer)
  /api/wireless/link, /api/devices[...]
  /__state                 test introspection (JSON of what was stored)
  /__bump/<id>             simulate a save from another device (revision + 1)
  /__share                 test-only: publish a share of a seeded project's video
                           ({projectId, videoId?, fileName?, isPrivate?}); it lists
                           in /api/videos and streams from /api/video/:id
  DELETE /api/me           account deletion (apps/api account-deletion contract):
                           200 {deleted, jobId, cancelledSubscriptions, cleanup}
                           and the session token stops working (a retry is 401)
  /__delete-me             test-only (POST): how the NEXT DELETE /api/me answers —
                           {"status": 409|502|403|429|500} with the API's body, or
                           {"mode": "drop"} (connection closed, no response), for
                           the next "count" calls (default 1); then back to 200.
                           GET /__state reports `deleteMe` (calls, answers, the
                           bearer each carried)
  /__session               test-only (GET): a session for the CURRENT token, in
                           /api/desktop/token's shape (gates skip the browser leg)

  The PUBLIC share endpoints the in-app share viewer reads (App/ShareViewer;
  apps/api/src/routes/{video,hub,analytics,video-report}.ts, same shapes and
  gates — no account needed; a bearer only attaches who is commenting):
  /api/video/:id/meta[?token]      open meta | {videoId, fileName, gate, brandAccent} |
                                   410 {error:"removed", message} | 404 (missing / private)
  /api/video/:id/unlock            POST {password} → {token} | 403 | 429 (after 10)
  /api/video/:id[?token&v]         bytes (Range); 403 private unless the owner's bearer;
                                   403 locked without a valid token; 410 expired
  /api/video/:id/comments[?token]  GET {comments, viewer} / POST {body, authorName?,
                                   videoTime?, parentId?, annotation?} — 404 when comments are off;
                                   the annotation (a drawing, {v: 1, shapes}) is stored as sent
                                   and the raw request body is logged (`raw`)
  PATCH /api/video/:id/comments-enabled  owner (bearer) of a LISTED share: {commentsEnabled}
                                   → {videoId, commentsEnabled}; 403 upgrade_required when the
                                   plan has no comments (control noCommentsPlan); 500 while
                                   failCommentsToggle > 0
  /api/video/:id/reactions         GET ?session → {reactions, mine}; POST {emoji,
                                   videoTime, sessionId} → {ok, mine} (same emoji toggles off)
  /api/video/:id/transcript        {segments}
  /api/video/:id/analytics[?token] POST {sessionId, events} (recorded)
  /api/video/:id/report            POST {reason, details?} → 201 {reported}
  /__viewer-share          test-only (POST): seed one such share — {videoId, file (base64
                           mp4), fileName, durationSeconds, commentsEnabled, allowDownload,
                           aiTitle, aiSummary, aiChapters, transcript, password, gate
                           ("expired"|"view_limit"|"paused"), isPrivate, ownedByMock,
                           removed (message), comments (each may carry an annotation),
                           reactions, annotations (the owner's markers), brandAccent,
                           listed (also a row of the signed-in user's GET /api/videos)}
  /__viewer-control        test-only (POST): {failReactions: n} — the next n reaction
                           POSTs answer 500; {failComments: n}, {failCommentsToggle: n} likewise;
                           {noCommentsPlan: 1} — /api/me's plan loses comments
  GET /__state             includes `viewer`: per-share request log (meta, stream, unlock,
                           comments, reactions, analytics, reports, with the bearer each carried)

Usage: python3 mock_api.py [port]   (binds 127.0.0.1 only)
"""
import base64
import hashlib
import json
import re
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlparse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8799
BASE = f"http://127.0.0.1:{PORT}"
TOKEN = "mock-session-token-" + uuid.uuid4().hex
LOCK = threading.Lock()

auth_requests = {}  # code -> {challenge, redirect_uri}
objects = {}  # sha -> bytes
pending = {}  # sha -> {bytes, contentType}
projects = {}  # ID -> {name, revision, document, files, staged, finalize_calls, created, updated}
comments = {"V1": [{"commentId": "C1", "parentId": None, "authorName": "Alex", "authorImage": None, "isOwner": False,
                    "body": "Love the zoom here", "videoTime": 3.2, "createdAt": "2026-11-12T10:00:00.000Z"}]}
devices = {}
shares = {}  # videoId -> {row (GET /api/videos shape), sha}
LINK_KEY = bytes(range(32))
viewer = {}  # videoId -> seeded public share (see /__viewer-share)
viewer_log = []  # [{route, videoId, method, query, authorization, body}]
viewer_control = {"failReactions": 0, "failComments": 0, "failCommentsToggle": 0, "noCommentsPlan": 0}
REACTION_EMOJI = ["\U0001F44D", "\u2764\ufe0f", "\U0001F525", "\U0001F602", "\U0001F62E", "\U0001F389"]
delete_me = {"next": None, "calls": []}  # /__delete-me control + DELETE /api/me log
DELETE_ME_BODIES = {
    409: {"error": "You own the team \u201cAcme\u201d with 2 other members. Make another member an owner, or remove them, on the Team page first.",
          "code": "team_has_members", "team": {"id": "org-acme", "name": "Acme", "otherMembers": 2}},
    502: {"error": "We couldn't cancel your subscription, so nothing was deleted. Try again in a moment.", "code": "billing_unavailable"},
    403: {"error": "Account blocked"},
    429: {"error": "Too many requests"},
    500: {"error": "Internal error"},
}


def b64url(data):
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())


def key_id(key):
    return hashlib.sha256(b"capturecat-wireless-link-v1" + key).digest()[:8].hex()


UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("mock_api: " + (fmt % args) + "\n")

    # ── helpers
    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def send_json(self, status, obj, headers=None):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def authed(self):
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            self.send_json(401, {"error": "Invalid or expired session"})
            return False
        return True

    def summary(self, pid, p):
        return {"projectId": pid, "name": p["name"], "revision": p["revision"], "hasDocument": p["revision"] > 0,
                "documentSha256": hashlib.sha256(p["document"].encode()).hexdigest() if p["document"] else None,
                "totalBytes": sum(f["bytes"] for f in p["files"]), "orgId": None, "isOwner": True,
                "createdAt": p["created"], "updatedAt": p["updated"]}

    # ── public share endpoints (the share viewer)
    def bearer_is_mock(self):
        return self.headers.get("Authorization") == f"Bearer {TOKEN}"

    def viewer_token_ok(self, vid, query):
        return query.get("token") == f"unlock-{vid}"

    def viewer_gate(self, v, vid, query):
        """apps/api routes/video.ts shareGate: locked / expired / view_limit / paused / open."""
        if v.get("gate"):
            return v["gate"]
        if v.get("password") and not self.viewer_token_ok(vid, query):
            return "locked"
        return "open"

    def viewer_log_entry(self, route, vid, raw=b""):
        try:
            body = json.loads(raw) if raw else None
        except Exception:
            body = None
        with LOCK:
            viewer_log.append({"route": route, "videoId": vid, "method": self.command, "query": urlparse(self.path).query,
                               "authorization": self.headers.get("Authorization"), "body": body,
                               "raw": raw.decode("utf-8", "replace") if raw else None})

    def viewer_public_comment(self, v, c):
        out = {k: c[k] for k in ("commentId", "parentId", "authorName", "authorImage", "body", "videoTime", "createdAt")}
        out["isOwner"] = bool(c.get("authorUid")) and c.get("authorUid") == v.get("ownerUid")
        out["annotation"] = c.get("annotation")
        return out

    def viewer_route(self, method, path, query, raw):
        """True when the request was a seeded share's public endpoint (answered)."""
        m = re.match(r"^/api/video/([^/]+)(/meta|/unlock|/comments|/reactions|/transcript|/analytics|/report|/download)?$", path)
        if m and m.group(1) not in viewer and m.group(2) == "/meta":
            # The real /meta is public: an unknown id is a plain 404 (never a 401).
            self.send_json(404, {"error": "Video not found"})
            return True
        if not m or m.group(1) not in viewer:
            return False
        vid, sub = m.group(1), (m.group(2) or "")
        v = viewer[vid]
        self.viewer_log_entry(sub.strip("/") or "stream", vid, raw)
        public = not v.get("isPrivate") and not v.get("removed")
        if sub == "/meta" and method == "GET":
            if v.get("isPrivate"):
                self.send_json(404, {"error": "Video not found"})
                return True
            if v.get("removed"):
                self.send_json(410, {"error": "removed", "message": v["removed"]})
                return True
            gate = self.viewer_gate(v, vid, query)
            if gate != "open":
                self.send_json(200, {"videoId": vid, "fileName": v["fileName"], "gate": gate, "brandAccent": None})
                return True
            self.send_json(200, {
                "videoId": vid, "fileName": v["fileName"], "contentType": "video/mp4", "fileSizeBytes": len(objects[v["sha"]]),
                "durationSeconds": v["durationSeconds"], "createdAt": v["createdAt"], "commentsEnabled": v["commentsEnabled"],
                "allowDownload": v["allowDownload"], "brandAccent": v.get("brandAccent"), "gate": "open", "aiTitle": v.get("aiTitle"),
                "aiSummary": v.get("aiSummary"), "aiChapters": v.get("aiChapters", []), "hasTranscript": len(v.get("transcript", [])) > 0,
                "annotations": v.get("annotations", []), "currentVersion": 1, "showVersionHistory": False, "ctaLabel": None, "ctaUrl": None,
                "thumbnailUrl": None, "versions": []})
            return True
        if sub == "/unlock" and method == "POST":
            if not public:
                self.send_json(404, {"error": "Video not found"})
                return True
            v["unlockAttempts"] = v.get("unlockAttempts", 0) + 1
            if v["unlockAttempts"] > 10:
                self.send_json(429, {"error": "Too many attempts"})
                return True
            if not v.get("password"):
                self.send_json(400, {"error": "Not password protected"})
                return True
            data = json.loads(raw or b"{}")
            if data.get("password") != v["password"]:
                self.send_json(403, {"error": "Wrong password"})
                return True
            self.send_json(200, {"token": f"unlock-{vid}"})
            return True
        if sub == "" and method == "GET":
            owner = v.get("ownedByMock") and self.bearer_is_mock()
            if v.get("removed") and not owner:
                self.send_json(410, {"error": "removed", "message": v["removed"]})
                return True
            if v.get("isPrivate"):
                if not owner:
                    self.send_json(403, {"error": "This video is private"})
                    return True
            else:
                gate = self.viewer_gate(v, vid, query)
                if gate == "locked":
                    self.send_json(403, {"error": "Password required"})
                    return True
                if gate == "expired":
                    self.send_json(410, {"error": "This link has expired"})
                    return True
                if gate != "open":
                    self.send_json(403, {"error": "This share is paused" if gate == "paused" else "View limit reached"})
                    return True
            self.serve_file(v["sha"])
            return True
        commentable = public and v["commentsEnabled"] and self.viewer_gate(v, vid, query) == "open"
        if sub == "/comments" and method == "GET":
            if not commentable:
                self.send_json(404, {"error": "Comments unavailable"})
                return True
            me = self.bearer_is_mock()
            self.send_json(200, {"comments": [self.viewer_public_comment(v, c) for c in v["comments"]],
                                 "viewer": {"name": "Test User", "image": None, "isOwner": bool(v.get("ownedByMock"))} if me else None})
            return True
        if sub == "/comments" and method == "POST":
            if not commentable:
                self.send_json(404, {"error": "Comments unavailable"})
                return True
            if viewer_control["failComments"] > 0:
                viewer_control["failComments"] -= 1
                self.send_json(500, {"error": "Could not post comment"})
                return True
            data = json.loads(raw or b"{}")
            body = data.get("body").strip() if isinstance(data.get("body"), str) else ""
            if not body or len(body) > 500:
                self.send_json(400, {"error": "Comment must be 1-500 characters"})
                return True
            me = self.bearer_is_mock()
            typed = data.get("authorName").strip()[:40] if isinstance(data.get("authorName"), str) else ""
            parent = data.get("parentId")
            t = data.get("videoTime") if isinstance(data.get("videoTime"), (int, float)) else 0
            if parent:
                p = next((c for c in v["comments"] if c["commentId"] == parent and not c["parentId"]), None)
                if not p:
                    self.send_json(400, {"error": "Reply target not found"})
                    return True
                t = p["videoTime"]
            annotation = data.get("annotation")
            if annotation is not None and (parent or not isinstance(annotation, dict) or annotation.get("v") != 1
                                           or not isinstance(annotation.get("shapes"), list) or not annotation["shapes"]):
                self.send_json(400, {"error": "Invalid drawing"})
                return True
            c = {"commentId": uuid.uuid4().hex[:16], "parentId": parent or None,
                 "authorName": "Test User" if me else (typed or "Anonymous"),
                 "authorImage": None, "authorUid": "mock-user" if me else None, "body": body,
                 "videoTime": max(0, min(float(t), v["durationSeconds"])), "createdAt": now_iso(),
                 "annotation": annotation}
            v["comments"].append(c)
            self.send_json(200, {"comment": self.viewer_public_comment(v, c)})
            return True
        if sub == "/reactions":
            if not public:
                self.send_json(404, {"error": "Video not found"})
                return True
            if method == "GET":
                session = query.get("session", "")
                mine = next(({"emoji": r["emoji"], "videoTime": r["videoTime"]} for r in v["reactions"] if r["session"] == session), None)
                rows = sorted(({"emoji": r["emoji"], "videoTime": r["videoTime"]} for r in v["reactions"]), key=lambda r: r["videoTime"])
                self.send_json(200, {"reactions": rows, "mine": mine})
                return True
            if viewer_control["failReactions"] > 0:
                viewer_control["failReactions"] -= 1
                self.send_json(500, {"error": "Internal error"})
                return True
            data = json.loads(raw or b"{}")
            emoji = data.get("emoji", "")
            if emoji not in REACTION_EMOJI:
                self.send_json(400, {"error": "Unknown reaction"})
                return True
            session = data.get("sessionId") if re.match(r"^[A-Za-z0-9_-]{8,64}$", str(data.get("sessionId", ""))) else "anon"
            t = data.get("videoTime") if isinstance(data.get("videoTime"), (int, float)) else 0
            t = round(min(max(0, t), v["durationSeconds"]) * 10) / 10
            existing = next((r for r in v["reactions"] if r["session"] == session), None)
            if existing and existing["emoji"] == emoji:
                v["reactions"].remove(existing)
                mine = None
            else:
                if existing:
                    v["reactions"].remove(existing)
                v["reactions"].append({"emoji": emoji, "videoTime": t, "session": session})
                mine = {"emoji": emoji, "videoTime": t}
            self.send_json(200, {"ok": True, "mine": mine})
            return True
        if sub == "/transcript" and method == "GET":
            if not public:
                self.send_json(404, {"error": "Video not found"})
                return True
            self.send_json(200, {"segments": v.get("transcript", [])})
            return True
        if sub == "/analytics" and method == "POST":
            if not public or (v.get("password") and not self.viewer_token_ok(vid, query)):
                self.send_json(404, {"error": "Video not found"})
                return True
            self.send_json(200, {"ok": True})
            return True
        if sub == "/report" and method == "POST":
            if not public:
                self.send_json(404, {"error": "Video not found"})
                return True
            data = json.loads(raw or b"{}")
            if data.get("reason") not in ("spam", "sexual", "violence", "hate", "harassment", "illegal", "copyright", "other"):
                self.send_json(400, {"error": "Invalid reason"})
                return True
            self.send_json(201, {"reported": True})
            return True
        if sub == "/download" and method == "GET":
            self.serve_file(v["sha"])
            return True
        self.send_json(404, {"error": "Not found"})
        return True

    # ── routing
    def do_GET(self):
        url = urlparse(self.path)
        path = url.path
        if path == "/api/desktop/authorize":
            q = {k: v[0] for k, v in parse_qs(url.query).items()}
            if q.get("code_challenge_method") != "S256" or len(q.get("code_challenge", "")) != 43:
                return self.send_json(400, {"error": "bad pkce"})
            redirect = q.get("redirect_uri", "")
            if not re.match(r"^http://127\.0\.0\.1:\d+/capturecat-auth/callback$", redirect):
                return self.send_json(400, {"error": "bad redirect"})
            if q.get("client", "mac") not in ("mac", "ios"):
                return self.send_json(400, {"error": "bad client"})
            code = uuid.uuid4().hex
            with LOCK:
                auth_requests[code] = {"challenge": q["code_challenge"], "redirect_uri": redirect}
            target = redirect + "?" + urlencode({"code": code, "state": q.get("state", "")})
            self.send_response(302)
            self.send_header("Location", target)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path == "/__state":
            with LOCK:
                return self.send_json(200, {"projects": {k: {**v, "document": v["document"]} for k, v in projects.items()},
                                            "objects": {k: len(v) for k, v in objects.items()}, "devices": devices,
                                            "deleteMe": {"calls": delete_me["calls"], "pending": delete_me["next"]},
                                            "viewer": {"log": viewer_log, "shares": {k: {"comments": v["comments"], "reactions": v["reactions"]}
                                                                                     for k, v in viewer.items()}}})
        if path == "/__session":
            return self.send_json(200, {"token": TOKEN, "expiresAt": "2027-01-01T00:00:00.000Z",
                                        "user": {"id": "mock-user", "email": "tester@example.com", "name": "Test User", "image": None}})
        if path.startswith("/files/"):
            return self.serve_file(path.split("/")[2])
        if self.viewer_route("GET", path, {k: v[0] for k, v in parse_qs(url.query).items()}, b""):
            return
        if not self.authed():
            return
        if path == "/api/me":
            return self.send_json(200, {"uid": "mock-user", "email": "tester@example.com", "tier": "pro", "tester": False,
                                        "blocked": False, "plan": {"name": "pro", "displayName": "Pro"},
                                        "features": {"cloudShare": True, "commercialUse": True,
                                                     "comments": not viewer_control["noCommentsPlan"]},
                                        "limits": {"maxTotalStorageBytes": 107374182400},
                                        "sessionExpiresAt": "2027-01-01T00:00:00.000Z"})
        if path == "/api/cloud-projects":
            with LOCK:
                items = [self.summary(k, v) for k, v in projects.items() if v["revision"] > 0]
                used = sum(len(v) for v in objects.values())
            return self.send_json(200, {"projects": items, "storage": {"usedBytes": used, "limitBytes": 107374182400}})
        m = re.match(r"^/api/cloud-projects/([^/]+)(/files)?$", path)
        if m:
            pid = m.group(1).upper()
            with LOCK:
                p = projects.get(pid)
                if not p or p["revision"] == 0:
                    return self.send_json(404, {"error": "Project not found"})
                files = [{"path": f["path"], "sha256": f["sha256"], "bytes": f["bytes"], "contentType": f["contentType"],
                          "source": None, "url": f"{BASE}/files/{f['sha256']}"} for f in p["files"]]
                expires = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() + 900))
                if m.group(2):
                    return self.send_json(200, {"projectId": pid, "revision": p["revision"], "files": files, "urlsExpireAt": expires})
                return self.send_json(200, {**self.summary(pid, p), "access": "owner", "document": p["document"],
                                            "files": files, "urlsExpireAt": expires}, {"ETag": f'"{p["revision"]}"'})
        if path == "/api/videos":
            with LOCK:
                rows = sorted((s["row"] for s in shares.values()), key=lambda r: r["createdAt"], reverse=True)
                used = sum(r["fileSizeBytes"] for r in rows)
            return self.send_json(200, {"videos": rows, "storageUsedBytes": used, "storageLimitBytes": 107374182400})
        m = re.match(r"^/api/video/([^/]+)$", path)
        if m:
            share = shares.get(m.group(1))
            if not share:
                return self.send_json(404, {"error": "Video not found"})
            return self.serve_file(share["sha"])
        m = re.match(r"^/api/video/([^/]+)/comments$", path)
        if m:
            return self.send_json(200, {"comments": comments.get(m.group(1), []), "viewer": None})
        if path == "/api/wireless/link":
            return self.send_json(200, {"key": b64url(LINK_KEY), "keyId": key_id(LINK_KEY), "createdAt": now_iso()},
                                  {"Cache-Control": "no-store"})
        if path == "/api/devices":
            with LOCK:
                return self.send_json(200, {"devices": list(devices.values())})
        return self.send_json(404, {"error": "Not found"})

    def do_POST(self):
        url = urlparse(self.path)
        path = url.path
        raw = self.body()
        if path == "/__viewer-share":
            data = json.loads(raw or b"{}")
            media = base64.b64decode(data["file"])
            sha = hashlib.sha256(media).hexdigest()
            vid = data["videoId"]
            with LOCK:
                objects[sha] = media
                viewer[vid] = {"sha": sha, "fileName": data.get("fileName", "capturecat-share-" + vid + ".mp4"),
                               "durationSeconds": float(data.get("durationSeconds", 10)), "createdAt": data.get("createdAt", now_iso()),
                               "commentsEnabled": bool(data.get("commentsEnabled", True)), "allowDownload": bool(data.get("allowDownload", False)),
                               "aiTitle": data.get("aiTitle"), "aiSummary": data.get("aiSummary"), "aiChapters": data.get("aiChapters", []),
                               "transcript": data.get("transcript", []), "password": data.get("password"), "gate": data.get("gate"),
                               "isPrivate": bool(data.get("isPrivate", False)), "ownedByMock": bool(data.get("ownedByMock", False)),
                               "ownerUid": "mock-user" if data.get("ownedByMock") else "someone-else", "removed": data.get("removed"),
                               "comments": [{"parentId": None, "authorImage": None, "authorUid": None, "annotation": None, **c} for c in data.get("comments", [])],
                               "reactions": [{"session": "seed-" + str(i), **r} for i, r in enumerate(data.get("reactions", []))],
                               "annotations": data.get("annotations", []), "brandAccent": data.get("brandAccent")}
                if data.get("listed"):
                    shares[vid] = {"sha": sha, "row": {
                        "videoId": vid, "fileName": viewer[vid]["fileName"], "contentType": "video/mp4", "fileSizeBytes": len(media),
                        "durationSeconds": viewer[vid]["durationSeconds"], "isPrivate": False, "createdAt": viewer[vid]["createdAt"],
                        "url": f"https://capturecat.so/share/{vid}", "projectId": None, "allowDownload": False, "hasPassword": False,
                        "expiresAt": None, "maxViews": None, "commentsEnabled": viewer[vid]["commentsEnabled"], "profileVisible": False,
                        "thumbnailType": None, "thumbnailUrl": None, "removed": None}}
            return self.send_json(200, {"videoId": vid})
        if path == "/__viewer-control":
            data = json.loads(raw or b"{}")
            with LOCK:
                viewer_control.update({k: int(v) for k, v in data.items() if k in viewer_control})
            return self.send_json(200, viewer_control)
        if self.viewer_route("POST", path, {k: v[0] for k, v in parse_qs(url.query).items()}, raw):
            return
        if path == "/api/desktop/token":
            data = json.loads(raw or b"{}")
            with LOCK:
                req = auth_requests.pop(data.get("code", ""), None)
            if not req:
                return self.send_json(400, {"error": "invalid_grant"})
            challenge = b64url(hashlib.sha256(data.get("code_verifier", "").encode()).digest())
            if challenge != req["challenge"] or data.get("redirect_uri") != req["redirect_uri"]:
                return self.send_json(400, {"error": "invalid_grant"})
            return self.send_json(200, {"token": TOKEN, "expiresAt": "2027-01-01T00:00:00.000Z",
                                        "user": {"id": "mock-user", "email": "tester@example.com", "name": "Test User", "image": None}})
        if path == "/__seed":
            # Test-only: a committed project with one media file, as if a device had published it.
            data = json.loads(raw or b"{}")
            media = base64.b64decode(data["file"])
            sha = hashlib.sha256(media).hexdigest()
            pid = data["id"].upper()
            with LOCK:
                objects[sha] = media
                projects[pid] = {"name": data["name"], "revision": 1, "document": data["document"],
                                 "files": [{"path": data["path"], "sha256": sha, "bytes": len(media), "contentType": data["contentType"]}],
                                 "staged": None, "created": now_iso(), "updated": now_iso()}
            return self.send_json(200, {"projectId": pid, "revision": 1})
        if path == "/__rename":
            # Test-only: a rename saved by "another device" (revision + 1).
            data = json.loads(raw or b"{}")
            pid = data["id"].upper()
            with LOCK:
                p = projects[pid]
                doc = json.loads(p["document"])
                doc["name"] = data["name"]
                p["document"] = json.dumps(doc, indent=2)
                p["name"] = data["name"]
                p["revision"] += 1
                p["updated"] = now_iso()
                return self.send_json(200, {"revision": p["revision"]})
        if path == "/__share":
            # Test-only: a share exported from a seeded project (its first video file).
            data = json.loads(raw or b"{}")
            pid = data["projectId"].upper()
            vid = data.get("videoId") or uuid.uuid4().hex[:12]
            with LOCK:
                p = projects[pid]
                f = next(f for f in p["files"] if f["contentType"].startswith("video/"))
                row = {"videoId": vid, "fileName": data.get("fileName", p["name"] + ".mp4"), "contentType": "video/mp4",
                       "fileSizeBytes": f["bytes"], "durationSeconds": data.get("durationSeconds", 2.0),
                       "isPrivate": bool(data.get("isPrivate", False)), "createdAt": now_iso(),
                       "url": f"https://capturecat.so/share/{vid}", "projectId": pid, "allowDownload": True,
                       "hasPassword": bool(data.get("hasPassword", False)), "expiresAt": None, "maxViews": None,
                       "commentsEnabled": data.get("commentsEnabled", True), "profileVisible": False,
                       "thumbnailType": None, "thumbnailUrl": None, "removed": None}
                shares[vid] = {"row": row, "sha": f["sha256"]}
            return self.send_json(200, {"videoId": vid})
        if path == "/__delete-me":
            data = json.loads(raw or b"{}")
            with LOCK:
                delete_me["next"] = data or None
            return self.send_json(200, {"next": delete_me["next"]})
        if path.startswith("/__bump/"):
            pid = path.split("/")[2].upper()
            with LOCK:
                p = projects[pid]
                doc = json.loads(p["document"])
                doc["zoomRegions"] = doc.get("zoomRegions", []) + [{"id": str(uuid.uuid4()).upper(), "startTime": 1, "endTime": 3,
                                                                    "zoomLevel": 2, "focalPoint": {"x": 0.5, "y": 0.5}}]
                p["document"] = json.dumps(doc, indent=2)
                p["revision"] += 1
                p["updated"] = now_iso()
                return self.send_json(200, {"revision": p["revision"]})
        if not self.authed():
            return
        if path == "/api/desktop/revoke":
            return self.send_json(200, {"ok": True})
        m = re.match(r"^/api/cloud-projects/([^/]+)/finalize$", path)
        if m:
            pid = m.group(1).upper()
            with LOCK:
                p = projects.get(pid)
                if not p:
                    return self.send_json(404, {"error": "Project not found"})
                staged = p.get("staged")
                if staged is None:
                    return self.send_json(200, {"projectId": pid, "committed": True, "revision": p["revision"]})
                p["finalize_calls"] = p.get("finalize_calls", 0) + 1
                if p["finalize_calls"] == 1:
                    return self.send_json(202, {"projectId": pid, "committed": False, "status": "verifying"})
                missing = [f for f in staged if f["sha256"] not in objects]
                if missing:
                    return self.send_json(409, {"error": "Some files have not been uploaded yet", "code": "objects_missing",
                                                "missing": [{"sha256": f["sha256"], "paths": [f["path"]]} for f in missing]})
                p["files"] = staged
                p["staged"] = None
                return self.send_json(200, {"projectId": pid, "committed": True, "revision": p["revision"],
                                            "fileCount": len(staged), "totalBytes": sum(f["bytes"] for f in staged)})
        m = re.match(r"^/api/video/([^/]+)/comments$", path)
        if m:
            data = json.loads(raw or b"{}")
            c = {"commentId": uuid.uuid4().hex, "parentId": data.get("parentId"), "authorName": "Test User", "authorImage": None,
                 "isOwner": True, "body": data.get("body", ""), "videoTime": data.get("videoTime"), "createdAt": now_iso()}
            comments.setdefault(m.group(1), []).append(c)
            return self.send_json(200, {"comment": c})
        if path == "/api/wireless/link/rotate":
            return self.send_json(200, {"key": b64url(LINK_KEY), "keyId": key_id(LINK_KEY), "createdAt": now_iso()})
        return self.send_json(404, {"error": "Not found"})

    def do_PATCH(self):
        path = urlparse(self.path).path
        raw = self.body()
        m = re.match(r"^/api/video/([^/]+)/comments-enabled$", path)
        if not m:
            return self.send_json(404, {"error": "Not found"})
        vid = m.group(1)
        if vid in viewer:
            self.viewer_log_entry("comments-enabled", vid, raw)
        if not self.authed():
            return
        data = json.loads(raw or b"{}")
        if not isinstance(data.get("commentsEnabled"), bool):
            return self.send_json(400, {"error": "commentsEnabled must be a boolean"})
        with LOCK:
            share = shares.get(vid)
            if not share:
                return self.send_json(404, {"error": "Video not found"})
            if viewer_control["failCommentsToggle"] > 0:
                viewer_control["failCommentsToggle"] -= 1
                return self.send_json(500, {"error": "Internal error"})
            if data["commentsEnabled"] and viewer_control["noCommentsPlan"]:
                return self.send_json(403, {"error": "Viewer comments isn't included in the account's Free plan. The account owner can upgrade at https://app.capturecat.so/billing.",
                                            "code": "upgrade_required", "feature": "comments", "plan": "free"})
            share["row"]["commentsEnabled"] = data["commentsEnabled"]
            if vid in viewer:
                viewer[vid]["commentsEnabled"] = data["commentsEnabled"]
        return self.send_json(200, {"videoId": vid, "commentsEnabled": data["commentsEnabled"]})

    def do_PUT(self):
        path = urlparse(self.path).path
        raw = self.body()
        if path.startswith("/upload/"):
            sha = path.split("/")[2]
            with LOCK:
                want = pending.get(sha)
            if not want:
                return self.send_json(403, {"error": "AccessDenied"})
            if self.headers.get("Content-Type") != want["contentType"]:
                return self.send_json(403, {"error": "SignatureDoesNotMatch (content-type)"})
            if len(raw) != want["bytes"] or hashlib.sha256(raw).hexdigest() != sha:
                return self.send_json(400, {"error": "BadDigest"})
            with LOCK:
                objects[sha] = raw
                pending.pop(sha, None)
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if not self.authed():
            return
        m = re.match(r"^/api/cloud-projects/([^/]+)/project$", path)
        if m:
            pid = m.group(1).upper()
            match = re.match(r'^"(\d+)"$', self.headers.get("If-Match", ""))
            if not match:
                return self.send_json(428, {"error": "Send If-Match", "code": "revision_required"})
            try:
                doc = json.loads(raw.decode("utf-8"))
            except Exception:
                return self.send_json(400, {"error": "project.json is not valid JSON", "code": "invalid_document"})
            missing = [k for k, t in (("name", str), ("createdAt", (int, float)), ("duration", (int, float)), ("settings", dict), ("zoomRegions", list))
                       if not isinstance(doc.get(k), t)]
            if str(doc.get("id", "")).upper() != pid:
                return self.send_json(400, {"error": "project.json id does not match this project", "code": "id_mismatch"})
            if missing:
                return self.send_json(400, {"error": f"project.json is missing required keys: {', '.join(missing)}", "code": "invalid_document"})
            with LOCK:
                p = projects.get(pid)
                if not p:
                    return self.send_json(404, {"error": "Project not found"})
                if int(match.group(1)) != p["revision"]:
                    return self.send_json(409, {"error": "This project changed since your copy was loaded", "code": "revision_conflict",
                                                "revision": p["revision"], "document": p["document"]})
                p["document"] = raw.decode("utf-8")
                p["name"] = doc["name"].strip()[:200] or "Untitled"
                p["revision"] += 1
                p["updated"] = now_iso()
                return self.send_json(200, {"projectId": pid, "revision": p["revision"], "updatedAt": p["updated"]},
                                      {"ETag": f'"{p["revision"]}"'})
        m = re.match(r"^/api/cloud-projects/([^/]+)$", path)
        if m:
            pid = m.group(1).upper()
            if not UUID_RE.match(pid):
                return self.send_json(400, {"error": "Invalid project id"})
            data = json.loads(raw or b"{}")
            files = data.get("files", [])
            for f in files:
                if not re.match(r"^[0-9a-f]{64}$", f.get("sha256", "")):
                    return self.send_json(400, {"error": "bad sha"})
            with LOCK:
                p = projects.setdefault(pid, {"name": data.get("name", "Untitled"), "revision": 0, "document": None, "files": [],
                                              "created": now_iso(), "updated": now_iso()})
                p["staged"] = files
                p["finalize_calls"] = 0
                missing = []
                for f in files:
                    if f["sha256"] in objects:
                        continue
                    pending[f["sha256"]] = {"bytes": f["bytes"], "contentType": f["contentType"]}
                    missing.append({"sha256": f["sha256"], "bytes": f["bytes"], "contentType": f["contentType"], "paths": [f["path"]],
                                    "method": "PUT", "uploadUrl": f"{BASE}/upload/{f['sha256']}", "headers": {"Content-Type": f["contentType"]}})
                return self.send_json(200, {"projectId": pid, "revision": p["revision"], "documentSha256": None,
                                            "missing": missing, "presentCount": len(files) - len(missing), "expiresIn": 900})
        m = re.match(r"^/api/devices/([^/]+)$", path)
        if m:
            data = json.loads(raw or b"{}")
            did = m.group(1).lower()
            with LOCK:
                devices[did] = {"deviceId": did, "platform": data.get("platform"), "name": data.get("name"), "model": data.get("model"),
                                "systemVersion": data.get("systemVersion"), "appVersion": data.get("appVersion"),
                                "canPush": bool(data.get("apnsToken")), "lastSeenAt": now_iso()}
                return self.send_json(200, devices[did])
        return self.send_json(404, {"error": "Not found"})

    def do_DELETE(self):
        global TOKEN
        path = urlparse(self.path).path
        if path == "/api/me":
            with LOCK:
                behaviour = delete_me["next"] or {}
                remaining = int(behaviour.get("count", 1)) - 1
                delete_me["next"] = {**behaviour, "count": remaining} if behaviour and remaining > 0 else None
                valid = self.headers.get("Authorization") == f"Bearer {TOKEN}"
                answer = "drop" if behaviour.get("mode") == "drop" else (int(behaviour.get("status", 200)) if valid else 401)
                delete_me["calls"].append({"authorization": self.headers.get("Authorization"), "valid": valid, "answer": answer})
            if answer == "drop":
                # No response at all: the client sees the connection go.
                self.close_connection = True
                self.connection.shutdown(2)
                return
            if answer == 401:
                return self.send_json(401, {"error": "Invalid or expired session"})
            if answer != 200:
                return self.send_json(answer, DELETE_ME_BODIES.get(answer, {"error": "Error"}))
            with LOCK:
                # Everything the account owned goes, and the session dies with it.
                projects.clear()
                shares.clear()
                devices.clear()
                TOKEN = "mock-session-token-" + uuid.uuid4().hex
            return self.send_json(200, {"deleted": True, "jobId": "job-" + uuid.uuid4().hex[:8],
                                        "cancelledSubscriptions": 1, "cleanup": "pending"})
        if not self.authed():
            return
        m = re.match(r"^/api/cloud-projects/([^/]+)$", path)
        if m:
            with LOCK:
                projects.pop(m.group(1).upper(), None)
            return self.send_json(200, {"deleted": True})
        m = re.match(r"^/api/devices/([^/]+)$", path)
        if m:
            with LOCK:
                existed = devices.pop(m.group(1).lower(), None)
            return self.send_json(200 if existed else 404, {"deleted": True} if existed else {"error": "not_found"})
        return self.send_json(404, {"error": "Not found"})

    def serve_file(self, sha):
        data = objects.get(sha)
        if data is None:
            return self.send_json(404, {"error": "NoSuchKey"})
        rng = self.headers.get("Range")
        start, end = 0, len(data) - 1
        status = 200
        if rng:
            m = re.match(r"bytes=(\d*)-(\d*)", rng)
            if m:
                if m.group(1):
                    start = int(m.group(1))
                    end = int(m.group(2)) if m.group(2) else end
                else:
                    start = max(0, len(data) - int(m.group(2)))
                end = min(end, len(data) - 1)
                status = 206
        chunk = data[start:end + 1]
        self.send_response(status)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(len(chunk)))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
        self.end_headers()
        self.wfile.write(chunk)


if __name__ == "__main__":
    print(f"mock_api: {BASE} token={TOKEN[:24]}…", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
