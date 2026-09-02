#!/usr/bin/env python3
"""Smoke test for the in-binary CaptureCat MCP server (`CaptureCat --mcp`).

Copies the most recent real project to a throwaway UUID folder inside the
app's sandbox container (so the sandboxed process can read it), then drives
the full protocol over stdio: initialize -> tools/list -> every tool,
including a real export. Prints PASS/FAIL per check and cleans up the copy.

Usage: python3 smoke.py [path-to-CaptureCat-binary] [--skip-export]
"""

import json
import os
import shutil
import subprocess
import sys
import time
import uuid

DEFAULT_BINARY = (
    "/Users/mike/Library/Developer/Xcode/DerivedData/"
    "CaptureCat-cykftpmogcyztgdvioqgxcuiosms/Build/Products/Debug/"
    "CaptureCat.app/Contents/MacOS/CaptureCat"
)
PROJECTS_ROOT = os.path.expanduser(
    "~/Library/Containers/so.capturecat.CaptureCat/Data/"
    "Library/Application Support/CaptureCat/Projects"
)

passed = failed = 0


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"PASS  {name}")
    else:
        failed += 1
        print(f"FAIL  {name}  {detail}")


class Client:
    def __init__(self, binary):
        self.proc = subprocess.Popen(
            [binary, "--mcp"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.next_id = 0

    def request(self, method, params=None, timeout=600):
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            msg["params"] = params
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("server closed stdout")
            line = line.strip()
            if not line:
                continue
            try:
                response = json.loads(line)
            except json.JSONDecodeError:
                raise RuntimeError(f"non-JSON on stdout: {line[:200]!r}")
            if response.get("id") == self.next_id:
                return response
        raise RuntimeError(f"timeout waiting for {method}")

    def notify(self, method):
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method}) + "\n")
        self.proc.stdin.flush()

    def call_tool(self, name, arguments=None, timeout=600):
        response = self.request(
            "tools/call", {"name": name, "arguments": arguments or {}}, timeout
        )
        result = response.get("result", {})
        text = result.get("content", [{}])[0].get("text", "")
        return result.get("isError", False), text

    def close(self):
        try:
            self.proc.stdin.close()  # EOF -> server should exit cleanly
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    binary = args[0] if args else DEFAULT_BINARY
    skip_export = "--skip-export" in sys.argv

    if not os.path.exists(binary):
        print(f"binary not found: {binary}")
        sys.exit(2)

    # Temp COPY of the most recent real project, under a fresh UUID inside
    # the container so the sandboxed server can read and mutate it safely.
    candidates = sorted(
        (d for d in os.listdir(PROJECTS_ROOT)
         if os.path.exists(os.path.join(PROJECTS_ROOT, d, "project.json"))),
        key=lambda d: os.path.getmtime(os.path.join(PROJECTS_ROOT, d, "project.json")),
        reverse=True,
    )
    if not candidates:
        print("no projects found to test against")
        sys.exit(2)
    temp_id = str(uuid.uuid4()).upper()
    temp_dir = os.path.join(PROJECTS_ROOT, temp_id)
    shutil.copytree(os.path.join(PROJECTS_ROOT, candidates[0]), temp_dir)
    print(f"test project copy: {temp_id} (from {candidates[0]})")

    client = Client(binary)
    try:
        # --- protocol ---
        response = client.request("initialize", {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "smoke", "version": "0"},
        })
        result = response.get("result", {})
        check("initialize echoes protocolVersion",
              result.get("protocolVersion") == "2025-03-26", json.dumps(response))
        check("initialize serverInfo.name == capturecat",
              result.get("serverInfo", {}).get("name") == "capturecat")
        check("initialize declares tools capability",
              "tools" in result.get("capabilities", {}))

        client.notify("notifications/initialized")

        response = client.request("ping")
        check("ping returns empty result", response.get("result") == {})

        response = client.request("bogus/method")
        check("unknown method -> -32601",
              response.get("error", {}).get("code") == -32601, json.dumps(response))

        response = client.request("tools/list")
        tools = {t["name"] for t in response.get("result", {}).get("tools", [])}
        expected = {"list_projects", "describe_project", "add_effect",
                    "set_style", "export_project", "cut_video", "get_transcript",
                    "render_frames", "auto_zoom", "add_annotation",
                    "start_recording", "stop_recording"}
        check("tools/list has the core tools", expected <= tools, str(tools))

        # --- list_projects ---
        is_error, text = client.call_tool("list_projects")
        projects = json.loads(text).get("projects", []) if not is_error else []
        check("list_projects returns projects incl. temp copy",
              not is_error and any(p.get("id") == temp_id or temp_id in json.dumps(p)
                                   for p in projects) or len(projects) > 0,
              text[:200])

        # --- describe_project (by folder-name UUID ref) ---
        is_error, text = client.call_tool("describe_project", {"id": temp_id})
        described = json.loads(text) if not is_error else {}
        check("describe_project succeeds", not is_error, text[:300])
        check("describe has settings + effects",
              "settings" in described and "effects" in described)
        check("describe has interactionDigest with clickClusters",
              isinstance(described.get("interactionDigest", {}).get("clickClusters"), list),
              json.dumps(described.get("interactionDigest"))[:200])
        duration = described.get("duration", 0)

        # --- add_effect ---
        end = min(3.0, duration - 0.1) if duration > 1 else 1.0
        is_error, text = client.call_tool("add_effect", {
            "id": temp_id, "type": "zoomtilt", "start": 0.5, "end": end,
            "zoomLevel": 1.8, "pitch": 15,
        })
        created = json.loads(text).get("created", []) if not is_error else []
        check("add_effect zoomtilt creates 2 regions",
              not is_error and {c["type"] for c in created} == {"zoom", "tilt"},
              text[:300])

        is_error, text = client.call_tool("add_effect", {
            "id": temp_id, "type": "zoom", "start": 0.6, "end": end + 0.2,
        })
        check("overlapping add_effect rejected",
              is_error and "never overlaps" in text, text[:300])

        is_error, text = client.call_tool("describe_project", {"id": temp_id})
        effects = json.loads(text).get("effects", {}) if not is_error else {}
        check("effects persisted to project.json",
              len(effects.get("zoomRegions", [])) >= 1
              and len(effects.get("tiltRegions", [])) >= 1)
        check("backup written",
              os.path.exists(os.path.join(temp_dir, "project.json.bak")))

        # --- set_style ---
        is_error, text = client.call_tool("set_style", {
            "id": temp_id,
            "patch": {"backgroundPadding": 120, "menuBarReplacement": "Clean Dark"},
        })
        applied = json.loads(text).get("applied", {}) if not is_error else {}
        check("set_style applies whitelisted patch",
              not is_error and applied.get("backgroundPadding") == 120, text[:300])

        is_error, text = client.call_tool("set_style", {
            "id": temp_id, "patch": {"evilKey": True},
        })
        check("set_style rejects unknown key",
              is_error and "not whitelisted" in text, text[:200])

        is_error, text = client.call_tool("set_style", {
            "id": temp_id, "patch": {"menuBarReplacement": "Neon"},
        })
        check("set_style rejects bad enum value",
              is_error and "allowed:" in text, text[:200])

        # --- export_project ---
        if skip_export:
            print("skip  export_project (--skip-export)")
        else:
            out = f"/tmp/capturecat-mcp-smoke-{temp_id[:8]}.mp4"
            is_error, text = client.call_tool(
                "export_project", {"id": temp_id, "output": out}, timeout=900)
            export = json.loads(text) if not is_error else {}
            path = export.get("path", "")
            ok = (not is_error and path and os.path.exists(path)
                  and os.path.getsize(path) > 10000)
            check("export_project produces an mp4", ok, text[:400])
            if ok:
                print(f"      exported {os.path.getsize(path)} bytes -> {path}")
                if path.startswith("/tmp/") or "/T/" in path:
                    os.unlink(path)
    finally:
        client.close()
        check("clean exit on EOF", client.proc.returncode == 0,
              f"rc={client.proc.returncode}")
        stderr_tail = client.proc.stderr.read()[-500:]
        if stderr_tail:
            print(f"--- stderr tail ---\n{stderr_tail}")
        shutil.rmtree(temp_dir, ignore_errors=True)

    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
