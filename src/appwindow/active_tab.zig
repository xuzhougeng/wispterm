//! Index of the currently-active tab. Extracted from appwindow/tab.zig so
//! dependency-light modules (e.g. file_explorer) can read/write the active-tab
//! index without importing the heavy tab module (which pulls in
//! Surface / ai_chat / split_tree and thus the full app graph).
pub threadlocal var g_active_tab: usize = 0;
