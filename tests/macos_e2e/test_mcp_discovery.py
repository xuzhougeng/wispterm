"""End-to-end: the real WispTerm.app, at startup, reads mcp.json and runs MCP
discovery against a configured server (spawn → initialize → tools/list).

This is the one part of the MCP path that is only compile-verified by the unit
suite — the session wiring that turns a config file into a live discovery run.
The test needs no LLM and no synthetic input: it points mcp.json at a fake MCP
server that records every JSON-RPC method it receives, launches the app with an
isolated HOME, and asserts the server got the discovery handshake.
"""

import json
import os
import signal
import subprocess
import sys
import tempfile
import time

import pytest

from tests.macos_e2e.conftest import APP_BUNDLE, macos_only

# A minimal but real MCP stdio server: records each method to a file (so the
# test can prove the app talked to it) and answers initialize + tools/list.
# It keeps reading stdin until EOF so it stays alive until the app closes it.
_FAKE_MCP_SERVER = '''
import sys, json
record_path = sys.argv[1]

def rec(method):
    with open(record_path, "a") as f:
        f.write(method + "\\n")

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\\n")
    sys.stdout.flush()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except Exception:
        continue
    method, mid = msg.get("method"), msg.get("id")
    rec(method or "?")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
            "serverInfo": {"name": "e2e-fake", "version": "1"}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [
            {"name": "e2e_probe", "description": "probe", "inputSchema": {"type": "object"}}]}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "nope"}})
'''


def _wispterm_pids() -> set:
    out = subprocess.run(["/usr/bin/pgrep", "-x", "WispTerm"], capture_output=True, text=True).stdout
    return set(out.split())


@pytest.mark.e2e
@macos_only
def test_mcp_servers_discovered_at_startup():
    if not os.path.exists(os.path.join(APP_BUNDLE, "Contents", "MacOS", "WispTerm")):
        pytest.skip(f"missing {APP_BUNDLE}; run `make test-macos-e2e` (builds it first)")

    home = tempfile.mkdtemp(prefix="wispterm-mcp-e2e-")
    pid = None
    try:
        cfg_dir = os.path.join(home, "Library", "Application Support", "wispterm")
        os.makedirs(cfg_dir, exist_ok=True)
        # Minimal config; pre-mark the AI-setup wizard so nothing blocks startup.
        with open(os.path.join(cfg_dir, "config"), "w") as f:
            f.write("agent-control-enabled = true\nauto-update-check = false\nlanguage = en\n")
        with open(os.path.join(cfg_dir, "state"), "w") as f:
            f.write("ai-setup-prompted = 1\n")

        server_path = os.path.join(home, "fake_mcp_server.py")
        record_path = os.path.join(home, "mcp_requests.log")
        with open(server_path, "w") as f:
            f.write(_FAKE_MCP_SERVER)
        mcp_config = {"mcpServers": {"e2e": {"command": sys.executable, "args": [server_path, record_path]}}}
        with open(os.path.join(cfg_dir, "mcp.json"), "w") as f:
            json.dump(mcp_config, f)

        env = dict(os.environ)
        env["HOME"] = home
        before = _wispterm_pids()
        # `-n` forces a fresh instance; `open` propagates our isolated HOME.
        subprocess.run(["/usr/bin/open", "-n", "-a", APP_BUNDLE], env=env, check=True)

        # Resolve the newly-launched app pid so we can terminate it in teardown.
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and pid is None:
            new = _wispterm_pids() - before
            if new:
                pid = int(sorted(new)[0])
            else:
                time.sleep(0.2)

        # Startup discovery is synchronous (main.zig), so the fake server should
        # receive the handshake within a couple of seconds of launch.
        methods = []
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if os.path.exists(record_path):
                methods = open(record_path).read().split()
                if "initialize" in methods and "tools/list" in methods:
                    break
            time.sleep(0.3)

        assert "initialize" in methods, f"app never sent initialize to the MCP server; recorded {methods}"
        assert "tools/list" in methods, f"app never sent tools/list to the MCP server; recorded {methods}"
    finally:
        if pid is not None:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        import shutil

        shutil.rmtree(home, ignore_errors=True)
