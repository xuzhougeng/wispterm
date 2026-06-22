import pytest
from tests.macos_e2e.conftest import macos_only


@pytest.mark.e2e
@macos_only
def test_edit_copy_menu_is_readable(app):
    # Smoke-test the osascript -> AX menu-state read pipeline against the real app.
    # WispTerm keeps Edit > Copy always enabled (verified empirically), so reading
    # it must return enabled=True. This validates that menu state can be queried
    # end-to-end; it does not assert selection-tracking (Copy does not gate on it).
    state = app.menu_item_state("Edit", "Copy")
    assert state.enabled is True
