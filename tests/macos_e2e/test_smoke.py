import pytest


@pytest.mark.e2e
def test_echo_roundtrip(app, pane):
    # End-to-end smoke test of a real isolated WispTerm.app instance: drive a
    # command through the control channel and read the result back. This
    # exercises launch + config + control server + shell + get-text against a
    # live GUI instance.
    #
    # NOTE: text is injected via the control channel (send_text), not synthetic
    # OS keyboard events. A test-launched instance does not process synthetic
    # input actions through to the PTY — see issue #279. `app.text()` (real
    # CGEvent keyboard) is kept on the driver for when that is resolved.
    app.send_text("echo hello-e2e\n")
    app.wait_for(pane, "hello-e2e", timeout=8)
