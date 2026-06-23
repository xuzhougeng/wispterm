import json
import os
import time

import pytest

from tests.macos_e2e.conftest import APP_BUNDLE, CTL_BINARY
from tests.macos_e2e.driver.macos import MacDriver


def _session_record(session_id: str, title: str, model: str, updated_at_ms: int, copilot: bool):
    return {
        "session_id": session_id,
        "title": title,
        "base_url": "https://api.example.com",
        "api_key": "k",
        "model": model,
        "protocol": "chat_completions",
        "system_prompt": "sys",
        "thinking_enabled": False,
        "reasoning_effort": "low",
        "stream": True,
        "max_tokens": 8192,
        "agent_enabled": True,
        "vision_enabled": False,
        "copilot": copilot,
        "created_at": updated_at_ms,
        "updated_at": updated_at_ms,
        "messages": [{"role": "user", "content": f"hello from {title}"}],
    }


@pytest.fixture()
def seeded_app():
    """A fresh isolated WispTerm instance pre-seeded with copilot history sessions.

    Writing only sessions/*.json (no index.json) exercises the storage layer's
    index-rebuild path on first launch.
    """
    driver = MacDriver(app_bundle=APP_BUNDLE, ctl_binary=CTL_BINARY)
    sessions_dir = os.path.join(driver._config_dir(), "agent-history", "sessions")
    os.makedirs(sessions_dir, exist_ok=True)
    now_ms = int(time.time() * 1000)
    day = 86400 * 1000
    seeds = [
        _session_record("hist-deploy", "Deploy notes", "deepseek-v4", now_ms, False),
        _session_record("hist-sidebar", "Sidebar chat", "glm-5", now_ms - day, True),
        _session_record("hist-old", "Old planning", "gpt-x", now_ms - 20 * day, False),
    ]
    for rec in seeds:
        with open(os.path.join(sessions_dir, f"{rec['session_id']}.json"), "w") as f:
            json.dump(rec, f)
    driver.launch()
    yield driver
    driver.quit()


@pytest.mark.e2e
@pytest.mark.macos_only
def test_copilot_history_input_driven(seeded_app):
    app = seeded_app
    app.focus()
    pane = app.primary_pane()

    # Baseline: app alive and terminal round-trips.
    app.send_text("echo before-history\n")
    app.wait_for(pane, "before-history", timeout=8)

    # Open command palette (Ctrl+Shift+P), select the "Copilot History" command to
    # enter history mode (default locale is English).
    app.key("p", "ctrl", "shift")
    time.sleep(0.3)
    app.text("Copilot History")  # filter the command list to the history entry
    time.sleep(0.3)
    app.key("return")            # execute -> enters history mode (panel shows seeds)
    time.sleep(0.3)

    # Exercise the new history-mode input handlers (must not crash / not eat input).
    app.text("deploy")           # live title filter
    time.sleep(0.2)
    app.key("down")              # navigate (skips group headers)
    app.key("up")
    app.key("tab")               # cycle source filter all -> sidebar
    app.key("tab")               # -> tab
    time.sleep(0.2)
    app.key("escape")            # leave history mode
    app.key("escape")            # close palette

    # The whole overlay-input flow must leave the app responsive and must NOT have
    # eaten subsequent terminal input. (Overlay text is unobservable via get-text;
    # covered by unit tests instead.)
    app.send_text("echo after-history\n")
    app.wait_for(pane, "after-history", timeout=8)
