"""Pure parsing of `wisptermctl panes` JSON. No OS dependencies — unit-tested."""


def primary_pane_id(panes: dict) -> str:
    """Return the focused surface id of the active tab.

    Resolution order: the tab whose ``index`` equals ``activeTab`` (or the first
    terminal tab if none matches) → its ``focusedSurfaceId`` → else the first
    surface marked ``focused`` → else the first surface. Raises LookupError when
    no terminal surface exists.
    """
    tabs = panes.get("tabs", [])
    active = panes.get("activeTab", 0)

    tab = next((t for t in tabs if t.get("index") == active and t.get("surfaces")), None)
    if tab is None:
        tab = next((t for t in tabs if t.get("surfaces")), None)
    if tab is None:
        raise LookupError("no tab with a live surface")

    fsid = tab.get("focusedSurfaceId")
    if fsid:
        return fsid

    surfaces = tab.get("surfaces", [])
    focused = next((s for s in surfaces if s.get("focused")), None)
    if focused:
        return focused["id"]
    if surfaces:
        return surfaces[0]["id"]
    raise LookupError("active tab has no surfaces")
