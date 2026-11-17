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
                                            "deleteMe": {"calls": delete_me["calls"], "pending": delete_me["next"]}})
        if path == "/__session":
            return self.send_json(200, {"token": TOKEN, "expiresAt": "2027-01-01T00:00:00.000Z",
                                        "user": {"id": "mock-user", "email": "tester@example.com", "name": "Test User", "image": None}})
        if path.startswith("/files/"):
            return self.serve_file(path.split("/")[2])
        if not self.authed():
            return
        if path == "/api/me":
            return self.send_json(200, {"uid": "mock-user", "email": "tester@example.com", "tier": "pro", "tester": False,
                                        "blocked": False, "plan": {"name": "pro", "displayName": "Pro"},
                                        "features": {"cloudShare": True, "commercialUse": True},
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
        path = urlparse(self.path).path
        raw = self.body()
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
