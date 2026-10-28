#!/usr/bin/env python3
"""Smoke test for the in-binary CaptureCat MCP server (`CaptureCat --mcp`).

Copies the most recent real project to a throwaway UUID folder inside the
app's sandbox container (so the sandboxed process can read it), then drives
the full protocol over stdio: initialize (instructions) -> tools/list
(annotations) -> prompts -> every tool, including apply_edits (and an
all-or-nothing failure that must leave project.json byte-identical), undo,
a contact-sheet render with progress notifications, and a real export.
Prints PASS/FAIL per check and deletes the copy. The user's real projects
are only ever read.

Usage: python3 smoke.py [path-to-CaptureCat-binary] [--skip-export]
                        [--skip-render] [--transcribe]
                        [--projects-root DIR] [--fixture DIR] [--share-live]

--projects-root points at the Projects folder the binary actually uses: an
ad-hoc re-signed (unsandboxed) harness copy reads
~/Library/Application Support/CaptureCat/Projects, not the container.
--fixture copies that project folder (e.g. apps/web/.fixtures/parity/
06-cursor-hand-physics) instead of the most recent real project, rewriting
its id and media URLs — no real user data involved at all.

Sharing: the protocol/catalog checks always run (initialize negotiates
2025-11-25 and 2026-07-28, tools/list carries share_project/share_status
with outputSchema + all four annotation hints, structuredContent mirrors the
text). share_project's live refusal is only exercised while NO CaptureCat GUI
is running (it must say the app isn't running, and upload nothing) — with a
GUI up the call could put a real consent card in front of the user, so it is
skipped unless --share-live is passed.

--transcribe runs a real on-device transcription of the copy. The first run
downloads the Whisper model (~150 MB) into the app container, so it is
opt-in; without it only transcribe's argument validation is exercised.
"""

import base64
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
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

EXPECTED_TOOLS = {
    "list_projects", "list_notes", "search_captures", "describe_project",
    "get_transcript", "render_frames", "style_options",
    "apply_edits", "add_effect", "update_effect", "remove_effect", "auto_zoom",
    "add_annotation", "update_annotation", "remove_annotation",
    "add_blur", "remove_blur", "set_speed", "remove_speed", "set_trim",
    "cut_video", "set_style", "transcribe", "undo",
    "export_project", "list_capture_targets", "start_recording", "stop_recording",
    "share_project", "share_status",
}
READ_ONLY_TOOLS = {
    "list_projects", "list_notes", "search_captures", "describe_project",
    "get_transcript", "render_frames", "style_options", "list_capture_targets",
    "share_status",
}
STRUCTURED_TOOLS = {"list_projects", "describe_project", "share_project", "share_status"}
NEW_PROTOCOL_VERSIONS = ["2025-11-25", "2026-07-28"]
LATEST_PROTOCOL_VERSION = "2026-07-28"
EXPECTED_PROMPTS = {"polish_recording", "tighten_pacing", "vertical_social_cut",
                    "record_and_edit_demo"}

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
        self.notifications = []

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
            if "id" not in response and "method" in response:
                self.notifications.append(response)
                continue
            if response.get("id") == self.next_id:
                return response
        raise RuntimeError(f"timeout waiting for {method}")

    def notify(self, method):
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method}) + "\n")
        self.proc.stdin.flush()

    def call(self, name, arguments=None, timeout=600, progress_token=None):
        """Returns (is_error, content list)."""
        result = self.call_result(name, arguments, timeout, progress_token)
        return result.get("isError", False), result.get("content", [])

    def call_result(self, name, arguments=None, timeout=600, progress_token=None):
        """The whole CallToolResult (content, isError, structuredContent)."""
        params = {"name": name, "arguments": arguments or {}}
        if progress_token is not None:
            params["_meta"] = {"progressToken": progress_token}
        response = self.request("tools/call", params, timeout)
        return response.get("result", {})

    def call_tool(self, name, arguments=None, timeout=600, progress_token=None):
        """Returns (is_error, first text item)."""
        is_error, content = self.call(name, arguments, timeout, progress_token)
        text = content[0].get("text", "") if content else ""
        return is_error, text

    def call_json(self, name, arguments=None, timeout=600):
        is_error, text = self.call_tool(name, arguments, timeout)
        try:
            return is_error, json.loads(text) if not is_error else {}, text
        except json.JSONDecodeError:
            return True, {}, text

    def progress_for(self, token):
        return [n for n in self.notifications
                if n.get("method") == "notifications/progress"
                and n.get("params", {}).get("progressToken") == token]

    def close(self):
        try:
            self.proc.stdin.close()  # EOF -> server should exit cleanly
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()


def free_span(occupied, lo, hi, length):
    """First gap of `length` seconds in [lo, hi] not touching `occupied`."""
    cursor = lo
    for start, end in sorted(occupied):
        if start - cursor >= length:
            return cursor, cursor + length
        cursor = max(cursor, end)
    if hi - cursor >= length:
        return cursor, cursor + length
    return None


def schema_errors(value, schema, path="$"):
    """A small JSON-Schema subset (type/enum/required/properties/items/min/max)
    — enough to prove structuredContent matches the advertised outputSchema."""
    errors = []
    kind = schema.get("type")
    checks = {
        "object": lambda v: isinstance(v, dict),
        "array": lambda v: isinstance(v, list),
        "string": lambda v: isinstance(v, str),
        "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
        "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
        "boolean": lambda v: isinstance(v, bool),
    }
    if kind in checks and not checks[kind](value):
        return [f"{path}: expected {kind}, got {type(value).__name__}"]
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {value!r} not in enum")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path}: below minimum")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path}: above maximum")
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}: missing required {key}")
        for key, sub in schema.get("properties", {}).items():
            if key in value:
                errors.extend(schema_errors(value[key], sub, f"{path}.{key}"))
    if isinstance(value, list) and "items" in schema:
        for index, item in enumerate(value):
            errors.extend(schema_errors(item, schema["items"], f"{path}[{index}]"))
    return errors


def gui_running():
    """A CaptureCat GUI instance (anything but `--mcp` / harness runs)."""
    try:
        out = subprocess.run(["ps", "-axo", "args="], capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return True  # unknown → assume yes (never risk a real consent card)
    for line in out.splitlines():
        if re.search(r"CaptureCat\.app/Contents/MacOS/CaptureCat(\s|$)", line) and " --" not in line:
            return True
    return False


def copy_fixture(source, projects_root):
    """A parity-style fixture copy: fresh UUID, media copied, URLs rewritten."""
    temp_id = str(uuid.uuid4()).upper()
    temp_dir = os.path.join(projects_root, temp_id)
    os.makedirs(temp_dir)
    with open(os.path.join(source, "project.json")) as f:
        project = json.load(f)
    for name in ("recording.mp4", "cursor.json", "camera.mp4"):
        if os.path.exists(os.path.join(source, name)):
            shutil.copyfile(os.path.join(source, name), os.path.join(temp_dir, name))
    url = lambda name: "file://" + os.path.join(temp_dir, name)  # noqa: E731
    project["id"] = temp_id
    for key, name in (("videoURL", "recording.mp4"), ("cursorDataURL", "cursor.json"),
                      ("cameraVideoURL", "camera.mp4")):
        if project.get(key):
            project[key] = url(name)
    with open(os.path.join(temp_dir, "project.json"), "w") as f:
        json.dump(project, f, indent=2)
    return temp_id, temp_dir


def png_size(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", data[16:24])


def option(name):
    if name in sys.argv:
        index = sys.argv.index(name)
        if index + 1 < len(sys.argv):
            return sys.argv[index + 1]
    return None


def main():
    valued = {"--projects-root", "--fixture"}
    args, skip = [], False
    for a in sys.argv[1:]:
        if skip:
            skip = False
            continue
        if a in valued:
            skip = True
            continue
        if not a.startswith("--"):
            args.append(a)
    binary = args[0] if args else DEFAULT_BINARY
    skip_export = "--skip-export" in sys.argv
    skip_render = "--skip-render" in sys.argv
    run_transcribe = "--transcribe" in sys.argv
    share_live = "--share-live" in sys.argv
    projects_root = os.path.expanduser(option("--projects-root") or PROJECTS_ROOT)
    fixture = option("--fixture")

    if not os.path.exists(binary):
        print(f"binary not found: {binary}")
        sys.exit(2)

    if fixture:
        os.makedirs(projects_root, exist_ok=True)
        temp_id, temp_dir = copy_fixture(os.path.abspath(fixture), projects_root)
        print(f"test project copy: {temp_id} (fixture {fixture})")
    else:
        # Temp COPY of the most recent real project, under a fresh UUID inside
        # the container so the sandboxed server can read and mutate it safely.
        candidates = sorted(
            (d for d in os.listdir(projects_root)
             if os.path.exists(os.path.join(projects_root, d, "project.json"))),
            key=lambda d: os.path.getmtime(os.path.join(projects_root, d, "project.json")),
            reverse=True,
        )
        if not candidates:
            print("no projects found to test against")
            sys.exit(2)
        temp_id = str(uuid.uuid4()).upper()
        temp_dir = os.path.join(projects_root, temp_id)
        shutil.copytree(os.path.join(projects_root, candidates[0]), temp_dir,
                        ignore=shutil.ignore_patterns(".mcp-history"))
        print(f"test project copy: {temp_id} (from {candidates[0]})")
    project_json = os.path.join(temp_dir, "project.json")

    def file_bytes():
        with open(project_json, "rb") as f:
            return f.read()

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
              result.get("protocolVersion") == "2025-03-26", json.dumps(response)[:300])
        check("initialize serverInfo.name == capturecat",
              result.get("serverInfo", {}).get("name") == "capturecat")
        caps = result.get("capabilities", {})
        check("initialize declares tools + prompts capabilities",
              "tools" in caps and "prompts" in caps, json.dumps(caps))
        instructions = result.get("instructions", "")
        check("initialize carries the editing playbook instructions",
              "SOURCE" in instructions and "OUTPUT" in instructions
              and "apply_edits" in instructions and 30 <= instructions.count("\n") <= 90,
              f"{len(instructions)} chars, {instructions.count(chr(10))} lines")

        client.notify("notifications/initialized")

        response = client.request("ping")
        check("ping returns empty result", response.get("result") == {})

        response = client.request("bogus/method")
        check("unknown method -> -32601",
              response.get("error", {}).get("code") == -32601, json.dumps(response))

        response = client.request("tools/list")
        tool_list = response.get("result", {}).get("tools", [])
        tools = {t["name"]: t for t in tool_list}
        check("tools/list has exactly the expected tools",
              set(tools) == EXPECTED_TOOLS,
              f"missing={EXPECTED_TOOLS - set(tools)} extra={set(tools) - EXPECTED_TOOLS}")
        check("every tool has a title + annotations",
              all(t.get("title") and t.get("annotations", {}).get("title") for t in tool_list))
        check("read-only tools are marked readOnlyHint",
              all(tools[n]["annotations"].get("readOnlyHint") is True
                  for n in READ_ONLY_TOOLS if n in tools)
              and all(tools[n]["annotations"].get("readOnlyHint") is False
                      for n in set(tools) - READ_ONLY_TOOLS))
        check("set_style description summarises key groups",
              "canvas:" in tools.get("set_style", {}).get("description", ""))
        hints = ("readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint")
        check("every tool carries all four annotation hints as booleans",
              all(isinstance(t.get("annotations", {}).get(h), bool) for t in tool_list for h in hints),
              str([t["name"] for t in tool_list
                   if not all(isinstance(t.get("annotations", {}).get(h), bool) for h in hints)]))
        check("destructiveHint is false on every tool (no tool deletes)",
              all(t["annotations"].get("destructiveHint") is False for t in tool_list))
        check("outputSchema on list_projects, describe_project, share_project, share_status",
              all(tools.get(n, {}).get("outputSchema", {}).get("type") == "object" for n in STRUCTURED_TOOLS))
        share_tool = tools.get("share_project", {})
        share_input = share_tool.get("inputSchema", {})
        check("share_project: project_id required, closed input, privacy enum",
              share_input.get("required") == ["project_id"]
              and share_input.get("additionalProperties") is False
              and share_input.get("properties", {}).get("privacy", {}).get("enum")
              == ["unlisted", "public", "private"], json.dumps(share_input)[:300])
        share_hints = share_tool.get("annotations", {})
        check("share_project: write, open-world, not idempotent",
              share_hints.get("readOnlyHint") is False and share_hints.get("openWorldHint") is True
              and share_hints.get("idempotentHint") is False, json.dumps(share_hints))
        check("share_status: read-only, job_id required",
              tools.get("share_status", {}).get("annotations", {}).get("readOnlyHint") is True
              and tools.get("share_status", {}).get("inputSchema", {}).get("required") == ["job_id"])
        check("instructions explain the share consent",
              "share_project" in instructions and "approves" in instructions)

        # --- protocol negotiation (fresh connections) ---
        for version, expected in [(v, v) for v in NEW_PROTOCOL_VERSIONS] + [("1999-01-01",
                                                                            LATEST_PROTOCOL_VERSION)]:
            probe = Client(binary)
            try:
                negotiated = probe.request("initialize", {
                    "protocolVersion": version, "capabilities": {},
                    "clientInfo": {"name": "smoke", "version": "0"}}, timeout=60)
                got = negotiated.get("result", {}).get("protocolVersion")
                check(f"initialize {version} -> {expected}", got == expected, json.dumps(negotiated)[:200])
            finally:
                probe.close()

        # --- prompts ---
        response = client.request("prompts/list")
        prompts = {p["name"] for p in response.get("result", {}).get("prompts", [])}
        check("prompts/list has the workflow prompts", prompts == EXPECTED_PROMPTS, str(prompts))
        response = client.request("prompts/get", {
            "name": "polish_recording", "arguments": {"projectId": temp_id}})
        messages = response.get("result", {}).get("messages", [])
        prompt_text = messages[0]["content"]["text"] if messages else ""
        check("prompts/get returns a concrete plan",
              temp_id in prompt_text and "apply_edits" in prompt_text
              and "render_frames" in prompt_text, prompt_text[:200])
        response = client.request("prompts/get", {"name": "tighten_pacing", "arguments": {}})
        check("prompts/get without a required argument -> -32602",
              response.get("error", {}).get("code") == -32602, json.dumps(response)[:200])

        # --- list_projects ---
        result = client.call_result("list_projects")
        is_error = result.get("isError", False)
        text = (result.get("content") or [{}])[0].get("text", "")
        projects = json.loads(text).get("projects", []) if not is_error else []
        check("list_projects returns projects", not is_error and len(projects) > 0, text[:200])
        structured = result.get("structuredContent")
        check("list_projects structuredContent mirrors the text JSON",
              structured is not None and structured == json.loads(text) if not is_error else False)
        errors = schema_errors(structured, tools["list_projects"]["outputSchema"]) if structured else ["none"]
        check("list_projects structuredContent matches its outputSchema", not errors, str(errors[:3]))

        # --- describe_project structuredContent ---
        result = client.call_result("describe_project", {"id": temp_id})
        structured = result.get("structuredContent")
        errors = schema_errors(structured, tools["describe_project"]["outputSchema"]) if structured else ["none"]
        check("describe_project structuredContent matches its outputSchema", not errors, str(errors[:3]))
        error_result = client.call_result("describe_project", {"id": str(uuid.uuid4())})
        check("tool errors carry no structuredContent",
              error_result.get("isError") is True and "structuredContent" not in error_result)

        # --- share_project / share_status (refusals only — never a real share) ---
        is_error, text = client.call_tool("share_project", {})
        check("share_project without project_id is refused", is_error and "project_id" in text, text[:200])
        is_error, text = client.call_tool("share_project", {"project_id": str(uuid.uuid4())})
        check("share_project on an unknown project is refused", is_error and "not found" in text, text[:200])
        is_error, text = client.call_tool("share_project", {"project_id": temp_id, "approved": True})
        check("share_project refuses an 'approved' argument (approval is the user's click)",
              is_error and "Approval can only come from" in text, text[:200])
        is_error, text = client.call_tool("share_project", {"project_id": temp_id, "privacy": "everyone"})
        check("share_project refuses an unknown privacy", is_error and "privacy must be one of" in text,
              text[:200])
        if gui_running() and not share_live:
            print("skip  share_project live refusal (a CaptureCat GUI is running; --share-live to force)")
        else:
            started = time.time()
            is_error, text = client.call_tool("share_project", {"project_id": temp_id}, timeout=120)
            check("share_project with no app to ask refuses clearly (nothing uploaded)",
                  is_error and ("isn't running" in text or "can't approve agent shares" in text)
                  and "Nothing was uploaded" in text, text[:300])
            check("share_project refusal is immediate", time.time() - started < 15)
        is_error, text = client.call_tool("share_status", {"job_id": str(uuid.uuid4())})
        check("share_status on an unknown job is refused", is_error and "unknown job_id" in text, text[:200])
        is_error, text = client.call_tool("share_status", {"job_id": "../../etc/passwd"})
        check("share_status rejects a non-UUID job id", is_error and "job_id" in text, text[:200])
        response = client.request("ping")
        check("stdio loop still answers after the share calls", response.get("result") == {})

        # --- describe_project (by folder-name UUID ref) ---
        is_error, described, text = client.call_json("describe_project", {"id": temp_id})
        check("describe_project succeeds", not is_error, text[:300])
        check("describe has settings + effects + annotations + speedRegions",
              all(k in described for k in ("settings", "effects", "annotations", "speedRegions",
                                           "subtitles", "blurRegions")))
        check("describe has outputDuration and a pacing digest",
              "outputDuration" in described and isinstance(described.get("pacing"), dict),
              json.dumps(described.get("pacing"))[:300])
        check("describe has interactionDigest with clickClusters",
              isinstance(described.get("interactionDigest", {}).get("clickClusters"), list),
              json.dumps(described.get("interactionDigest"))[:200])
        duration = described.get("duration", 0)
        trim = described.get("trim", {"start": 0, "end": duration})
        lo, hi = trim["start"], trim["end"]

        def effect_spans(d):
            e = d.get("effects", {})
            return [(r["start"], r["end"]) for r in e.get("zoomRegions", []) + e.get("tiltRegions", [])]

        # --- add_effect ---
        span = free_span(effect_spans(described), lo, hi, 2.5)
        check("found a free effects-lane span", span is not None, str(effect_spans(described)))
        span = span or (lo, lo + 2.5)
        is_error, created_effect, text = client.call_json("add_effect", {
            "id": temp_id, "type": "zoomtilt", "start": span[0], "end": span[1],
            "zoomLevel": 1.8, "pitch": 15,
        })
        created = created_effect.get("created", [])
        check("add_effect zoomtilt creates 2 regions",
              not is_error and {c["type"] for c in created} == {"zoom", "tilt"}, text[:300])
        check("mutations report undoSteps", created_effect.get("undoSteps", 0) >= 1, text[:200])

        is_error, text = client.call_tool("add_effect", {
            "id": temp_id, "type": "zoom", "start": span[0] + 0.1, "end": span[1] + 0.2,
        })
        check("overlapping add_effect rejected",
              is_error and "never overlaps" in text, text[:300])

        is_error, text = client.call_tool("update_effect", {
            "id": temp_id, "at": span[0] + 0.1, "zoomLevel": 2.2, "animationStyle": "Smooth",
        })
        check("update_effect patches the block", not is_error and "zoom:" in text, text[:200])

        # Touching blocks: a boundary 'at' must hit exactly one of them.
        is_error, described, _ = client.call_json("describe_project", {"id": temp_id})
        gap = free_span(effect_spans(described), lo, hi, 4.0)
        if gap:
            a, b = gap[0], gap[0] + 2.0
            is_error, text = client.call_tool("apply_edits", {"id": temp_id, "ops": [
                {"op": "add_effect", "args": {"type": "zoom", "start": a, "end": b}},
                {"op": "add_effect", "args": {"type": "tilt", "start": b, "end": b + 2.0}},
            ]})
            check("touching effect blocks are allowed", not is_error, text[:200])
            is_error, removed, text = client.call_json("remove_effect", {"id": temp_id, "at": b})
            check("remove_effect at a shared boundary removes exactly one block",
                  not is_error and removed.get("removed") == 1, text[:200])
            client.call_tool("remove_effect", {"id": temp_id, "at": b + 1.0})

        is_error, described, text = client.call_json("describe_project", {"id": temp_id})
        effects = described.get("effects", {})
        check("effects persisted to project.json",
              len(effects.get("zoomRegions", [])) >= 1 and len(effects.get("tiltRegions", [])) >= 1)
        check("backup written",
              os.path.exists(os.path.join(temp_dir, "project.json.bak")))
        check("undo history written",
              os.path.isdir(os.path.join(temp_dir, ".mcp-history")))

        # --- set_style / style_options ---
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
            "id": temp_id, "patch": {"backgroundPaddng": 10},
        })
        check("set_style suggests the closest key",
              is_error and "backgroundPadding" in text, text[:200])

        is_error, text = client.call_tool("set_style", {
            "id": temp_id, "patch": {"menuBarReplacement": "Neon"},
        })
        check("set_style rejects bad enum value",
              is_error and "allowed:" in text, text[:200])

        is_error, options, text = client.call_json("style_options", {"id": temp_id})
        canvas = options.get("groups", {}).get("canvas", {})
        check("style_options lists enums from the real types + current values",
              not is_error and "9:16" in canvas.get("aspectRatio", {}).get("values", [])
              and canvas.get("backgroundPadding", {}).get("current") == 120, text[:300])

        # --- get_transcript / search_captures ---
        is_error, transcript, text = client.call_json("get_transcript", {"id": temp_id})
        check("get_transcript answers (segments or a transcribe hint)",
              not is_error and ("segments" in transcript), text[:200])
        is_error, text = client.call_tool("search_captures", {"query": "the"})
        check("search_captures answers", not is_error, text[:200])

        # --- apply_edits (success) ---
        is_error, described, _ = client.call_json("describe_project", {"id": temp_id})
        focus = [(r["start"], r["end"]) for r in described.get("blurRegions", [])
                 + described.get("highlightRegions", [])
                 + described.get("otherFocusLaneRegions", [])]
        blur_span = free_span(focus, lo, hi, 2.0) or (lo, lo + 2.0)
        speeds = [(r["start"], r["end"]) for r in described.get("speedRegions", [])]
        speed_span = free_span(speeds, lo + 3.0, hi, 2.0) or free_span(speeds, lo, hi, 2.0)
        ops = [
            {"op": "add_annotation", "args": {"type": "text", "start": lo + 0.5, "end": lo + 3.0,
                                              "text": "Smoke label", "x": 0.5, "y": 0.2}},
            {"op": "add_blur", "args": {"start": blur_span[0], "end": blur_span[1],
                                        "x": 0.05, "y": 0.05, "width": 0.3, "height": 0.1,
                                        "style": "Pixelate"}},
            {"op": "set_style", "args": {"patch": {"shadowOpacity": 0.4}}},
        ]
        if speed_span:
            ops.append({"op": "set_speed", "args": {"start": speed_span[0], "end": speed_span[1],
                                                    "speed": 2}})
        is_error, batch, text = client.call_json("apply_edits", {"id": temp_id, "ops": ops})
        check("apply_edits applies a mixed batch",
              not is_error and batch.get("applied") == len(ops), text[:400])
        results = {r["op"]: r["result"] for r in batch.get("results", [])}
        annotation_id = results.get("add_annotation", {}).get("created")
        blur_id = results.get("add_blur", {}).get("created")
        check("apply_edits returns created ids", bool(annotation_id) and bool(blur_id), text[:300])
        if speed_span:
            od = batch.get("outputDuration", {})
            check("set_speed shortens the output", od.get("after", 0) < od.get("before", 0), str(od))

        # --- apply_edits (all-or-nothing failure) ---
        before = file_bytes()
        is_error, text = client.call_tool("apply_edits", {"id": temp_id, "ops": [
            {"op": "add_annotation", "args": {"type": "arrow", "start": lo + 1, "end": lo + 2}},
            {"op": "add_effect", "args": {"type": "zoom", "start": span[0], "end": span[1]}},
        ]})
        check("apply_edits failure names the failing op",
              is_error and "ops[1]" in text and "Nothing was written" in text, text[:300])
        check("apply_edits failure leaves project.json byte-identical", file_bytes() == before)

        # --- update / remove annotation, remove_blur, speed, trim ---
        is_error, text = client.call_tool("update_annotation", {
            "id": temp_id, "annotationId": annotation_id, "text": "Updated label",
            "y": 0.8, "enterEffect": "Fade"})
        check("update_annotation patches by id", not is_error, text[:200])
        is_error, described, _ = client.call_json("describe_project", {"id": temp_id})
        ann = next((a for a in described.get("annotations", []) if a["id"] == annotation_id), {})
        check("describe lists the annotation with its new text",
              ann.get("text") == "Updated label" and ann.get("y") == 0.8, json.dumps(ann))
        is_error, text = client.call_tool("update_annotation", {
            "id": temp_id, "annotationId": annotation_id, "end": duration + 50})
        check("update_annotation validates the span", is_error and "SOURCE" in text, text[:200])

        is_error, text = client.call_tool("add_blur", {
            "id": temp_id, "start": blur_span[0], "end": blur_span[1], "x": 400, "y": 10,
            "width": 100, "height": 50})
        check("add_blur rejects pixel coordinates", is_error and "normalized" in text, text[:200])
        is_error, text = client.call_tool("remove_blur", {"id": temp_id, "blurId": blur_id})
        check("remove_blur removes by id", not is_error, text[:200])

        if speed_span:
            # Clamped to the recording so short fixtures hit the overlap rule,
            # not the end-of-recording one.
            is_error, text = client.call_tool("set_speed", {
                "id": temp_id, "start": speed_span[0] + 0.5, "end": min(speed_span[1] + 1, hi), "speed": 3})
            check("overlapping set_speed rejected", is_error and "overlaps" in text, text[:200])
            is_error, text = client.call_tool("set_speed", {
                "id": temp_id, "start": speed_span[0], "end": speed_span[1], "speed": 3})
            check("set_speed on the exact span changes the speed",
                  not is_error and "changed" in text, text[:200])
            is_error, text = client.call_tool("remove_speed", {"id": temp_id, "at": speed_span[0] + 0.1})
            check("remove_speed clears by time", not is_error, text[:200])
        is_error, text = client.call_tool("set_speed", {
            "id": temp_id, "start": lo, "end": lo + 2, "speed": 9})
        check("set_speed rejects out-of-range speed", is_error and "outside" in text, text[:200])

        is_error, trim_result, text = client.call_json("set_trim", {
            "id": temp_id, "start": lo + 0.25})
        check("set_trim moves the trim start",
              not is_error and abs(trim_result.get("trim", {}).get("start", 0) - (lo + 0.25)) < 0.002,
              text[:200])
        tiny = min(5.0, hi - 0.2)  # inside short fixtures too
        is_error, text = client.call_tool("set_trim", {"id": temp_id, "start": tiny, "end": tiny + 0.1})
        check("set_trim enforces the 0.5s minimum", is_error and "0.5s" in text, text[:200])

        # --- auto_zoom / cut_video / remove_effect / remove_annotation ---
        is_error, text = client.call_tool("auto_zoom", {"id": temp_id})
        check("auto_zoom runs (or explains why not)",
              not is_error or "no zoom-worthy" in text or "no recorded cursor" in text, text[:200])
        is_error, text = client.call_tool("remove_effect", {"id": temp_id, "at": span[0] + 0.1})
        check("remove_effect removes the block", not is_error or "no zoom/tilt" in text, text[:200])
        is_error, text = client.call_tool("cut_video", {
            "id": temp_id, "ranges": [{"start": hi - 1.5, "end": hi - 0.5}]})
        check("cut_video lifts a range", not is_error and "removedSeconds" in text, text[:200])
        is_error, text = client.call_tool("remove_annotation", {
            "id": temp_id, "annotationId": annotation_id})
        check("remove_annotation removes by id", not is_error, text[:200])

        # --- transcribe ---
        if run_transcribe:
            is_error, text = client.call_tool("transcribe", {"id": temp_id, "replace": True},
                                              timeout=1800, progress_token="tx")
            check("transcribe stores subtitles (or reports no speech / no audio)",
                  not is_error or "audio" in text, text[:300])
            check("transcribe emits progress notifications", len(client.progress_for("tx")) > 0)
        else:
            is_error, text = client.call_tool("transcribe", {"id": str(uuid.uuid4())})
            check("transcribe validates its project (full run: --transcribe)",
                  is_error and "not found" in text, text[:200])

        # --- render_frames (contact sheet + jpeg) ---
        if skip_render:
            print("skip  render_frames (--skip-render)")
        else:
            is_error, content = client.call("render_frames", {
                "id": temp_id, "layout": "contact_sheet", "span": {"count": 6}},
                timeout=1800, progress_token="render")
            images = [c for c in content if c.get("type") == "image"]
            header = json.loads(content[0]["text"]) if content and not is_error else {}
            check("render_frames contact_sheet returns ONE image + tile map",
                  not is_error and len(images) == 1 and len(header.get("tiles", [])) == 6,
                  (content[0].get("text", "") if content else "")[:300])
            if images:
                data = base64.b64decode(images[0]["data"])
                size = png_size(data)
                check("contact sheet is a PNG within the size cap",
                      size is not None and max(size) <= 1568, str(size))
                out = os.path.join(tempfile.gettempdir(), f"capturecat-smoke-sheet-{temp_id[:8]}.png")
                with open(out, "wb") as f:
                    f.write(data)
                print(f"      contact sheet -> {out}")
            check("fresh render emits progress notifications",
                  header.get("render") != "fresh export" or len(client.progress_for("render")) > 0)
            is_error, content = client.call("render_frames", {
                "id": temp_id, "times": [1.0], "format": "jpeg", "quality": 0.6})
            images = [c for c in content if c.get("type") == "image"]
            check("render_frames jpeg (cached) returns image/jpeg",
                  not is_error and len(images) == 1 and images[0].get("mimeType") == "image/jpeg"
                  and base64.b64decode(images[0]["data"])[:2] == b"\xff\xd8")

        # --- undo ---
        is_error, before_undo, _ = client.call_json("describe_project", {"id": temp_id})
        is_error, undo1, text = client.call_json("undo", {"id": temp_id})
        check("undo restores the previous state",
              not is_error and undo1.get("undone", [{}])[0].get("tool") == "remove_annotation", text[:300])
        is_error, after_undo, _ = client.call_json("describe_project", {"id": temp_id})
        check("undo brought the removed annotation back",
              any(a["id"] == annotation_id for a in after_undo.get("annotations", [])))
        is_error, undo2, text = client.call_json("undo", {"id": temp_id, "steps": 2})
        check("multi-step undo", not is_error and len(undo2.get("undone", [])) == 2, text[:300])

        with open(project_json, "ab") as f:
            f.write(b"\n")  # an outside edit (e.g. the app saving)
        is_error, text = client.call_tool("undo", {"id": temp_id})
        check("undo refuses after an outside change", is_error and "force" in text, text[:200])
        is_error, text = client.call_tool("undo", {"id": temp_id, "force": True})
        check("undo force: true overrides", not is_error, text[:200])

        # --- export_project ---
        if skip_export:
            print("skip  export_project (--skip-export)")
        else:
            out = f"/tmp/capturecat-mcp-smoke-{temp_id[:8]}.mp4"
            is_error, text = client.call_tool(
                "export_project", {"id": temp_id, "output": out}, timeout=1800,
                progress_token="export")
            export = json.loads(text) if not is_error else {}
            path = export.get("path", "")
            ok = (not is_error and path and os.path.exists(path)
                  and os.path.getsize(path) > 10000)
            check("export_project produces an mp4", ok, text[:400])
            check("export emits progress notifications", len(client.progress_for("export")) > 0)
            if ok:
                print(f"      exported {os.path.getsize(path)} bytes -> {path}")
                # Our own artifact: /tmp, or the sandbox fallback in the
                # container's tmp (…/Data/tmp/capturecat-export-…).
                if (path.startswith("/tmp/") or "/T/" in path
                        or "/Data/tmp/capturecat-export-" in path):
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
