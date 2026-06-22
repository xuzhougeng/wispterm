//! UI 文案国际化（i18n）核心：扁平字段目录 + 当前语言。
//! 设计见 docs/superpowers/specs/2026-06-01-i18n-infrastructure-design.md
const std = @import("std");
const builtin = @import("builtin");
const command_center_state = @import("command_center_state.zig");
const CommandAction = command_center_state.CommandAction;

pub const Lang = enum { en, zh_CN };

/// 调用点直接替换的扁平文案。字段无默认值 → 任一 locale 漏填某字段编译期报错，
/// 这是「方案 A」comptime 完整性保证的落地（无需手写 assert）。
pub const Strings = struct {
    /// 预留给未来的语言选择 UI；当前仅用于演示 catalog 与测试，生产代码暂未读取。
    language_name: []const u8,
    toast_wechat_not_connected: []const u8,
    toast_wechat_poller_started: []const u8,
    toast_wechat_poller_stopped: []const u8,
    toast_wechat_direct_disabled: []const u8,

    // —— 设置页 ——
    settings_title: []const u8,
    settings_subtitle: []const u8,
    settings_font_size: []const u8,
    settings_theme: []const u8,
    settings_cursor_style: []const u8,
    settings_cursor_blink: []const u8,
    settings_focus_follows_mouse: []const u8,
    settings_restore_tabs: []const u8,
    settings_shell: []const u8,
    settings_default_ai: []const u8,
    settings_weixin_direct: []const u8,
    settings_distill_suggest: []const u8,
    settings_language: []const u8,
    settings_raw_config: []const u8,
    settings_restore_defaults: []const u8,
    settings_close: []const u8,
    restore_defaults_title: []const u8,
    restore_defaults_body: []const u8,
    restore_defaults_hint: []const u8,
    restore_defaults_apply: []const u8,
    restore_defaults_cancel: []const u8,
    settings_hint_advanced_editor: []const u8,
    settings_hint_add_profiles: []const u8,
    settings_hint_restart: []const u8,
    settings_value_on: []const u8,
    settings_value_off: []const u8,
    settings_value_open: []const u8,
    settings_value_none: []const u8,
    settings_lang_auto: []const u8,

    // —— 会话启动器 & AI 智能体对话框 ——
    sl_new_session: []const u8,
    sl_ai_agent: []const u8,
    sl_sessions: []const u8,
    sl_sessions_detail: []const u8,
    sl_skill_center: []const u8,
    sl_skill_center_detail: []const u8,
    pf_title: []const u8,
    pf_detail: []const u8,
    pf_legend: []const u8,
    pf_form_legend: []const u8,

    // —— Skill Center 面板 ——
    sc_local: []const u8,
    sc_wsl: []const u8,
    sc_scanning: []const u8,
    sc_no_server: []const u8,
    sc_cached: []const u8,
    sc_offline: []const u8,
    sc_hint_same: []const u8,
    sc_hint_differ: []const u8,
    sc_hint_local_only: []const u8,
    sc_hint_remote_only: []const u8,
    sc_hint_unknown: []const u8,
    sc_legend: []const u8,
    sc_toast_synced: []const u8,
    sc_toast_sync_failed: []const u8,
    sc_busy_syncing: []const u8,
    sc_toast_op_busy: []const u8,
    sc_toast_sync_failed_prefix: []const u8,
    sc_toast_in_sync: []const u8,
    sc_toast_no_local: []const u8,
    sc_toast_no_remote: []const u8,
    sc_toast_no_conn: []const u8,
    sc_toast_read_failed: []const u8,
    sc_overwrite_upload: []const u8,
    sc_overwrite_download: []const u8,
    sc_confirm_suffix: []const u8,

    // —— Skill Center v2 (library + targets) ——
    sc_legend_v2: []const u8,
    sc_legend_import: []const u8,
    sc_busy_loading: []const u8,
    sc_tool_import_failed: []const u8,
    sc_tool_toggle_failed: []const u8,
    sc_tool_enabled: []const u8,
    sc_tool_disabled: []const u8,
    sc_pick_deploy: []const u8,
    sc_pick_import: []const u8,
    sc_import_title: []const u8,
    sc_sw_claude: []const u8,
    sc_sw_codex: []const u8,
    sc_marker_new: []const u8,
    sc_marker_same: []const u8,
    sc_marker_differ: []const u8,
    sc_toast_imported: []const u8,
    sc_empty: []const u8,
    sc_url_prompt: []const u8,
    sc_pick_install: []const u8,
    sc_preview_hint: []const u8,
    sc_busy_fetching: []const u8,
    sc_busy_installing: []const u8,
    sc_toast_installed: []const u8,
    sc_toast_install_partial: []const u8,
    sc_toast_no_skills: []const u8,
    sc_toast_bad_url: []const u8,
    sc_toast_truncated: []const u8,

    sl_llm_providers: []const u8,
    sl_new_llm_provider: []const u8,
    sl_edit_llm_provider: []const u8,
    sl_delete_llm_provider: []const u8,
    sl_ssh_server: []const u8,
    sl_ssh_servers: []const u8,
    sl_new_ssh_server: []const u8,
    sl_edit_ssh_server: []const u8,
    sl_delete_ssh_server: []const u8,
    sl_cancel: []const u8,
    sl_save: []const u8,
    sl_back: []const u8,
    sl_save_open: []const u8,
    sl_save_connect: []const u8,
    sl_v_add: []const u8,
    sl_v_choose: []const u8,
    sl_v_no_profile: []const u8,
    sl_v_no_server: []const u8,
    sl_v_manage: []const u8,
    sl_v_profile: []const u8,
    sl_v_agent: []const u8,
    sl_v_connect_server: []const u8,
    sl_hint_main: []const u8,
    sl_hint_ai_form: []const u8,
    sl_hint_ai_manage: []const u8,
    sl_hint_choose_profile_edit: []const u8,
    sl_hint_choose_profile_delete: []const u8,
    sl_hint_ssh_form: []const u8,
    sl_hint_ssh_filter_edits: []const u8,
    sl_hint_ssh_filter_manage: []const u8,
    sl_hint_ssh_filter_choose_edit: []const u8,
    sl_hint_choose_server_edit: []const u8,
    sl_hint_ssh_filter_choose_delete: []const u8,
    sl_hint_choose_server_delete: []const u8,
    sl_ai_profile_name: []const u8,
    sl_ai_base_url: []const u8,
    sl_ai_api_key: []const u8,
    sl_switch_model_title: []const u8,
    sl_switch_model_hint: []const u8,
    ai_summary_card_title: []const u8,
    ai_model_no_profiles: []const u8,
    ai_model_unknown_profile: []const u8,
    sl_ai_model: []const u8,
    sl_ai_system: []const u8,
    sl_ai_thinking: []const u8,
    sl_ai_effort: []const u8,
    sl_ai_stream: []const u8,
    sl_ai_agent_field: []const u8,
    sl_ai_protocol: []const u8,
    sl_ai_max_tokens: []const u8,
    sl_ai_vision: []const u8,
    sl_ssh_server_name: []const u8,
    sl_ssh_ip_host: []const u8,
    sl_ssh_user: []const u8,
    sl_ssh_password: []const u8,
    sl_ssh_port: []const u8,
    sl_ssh_jump_host: []const u8,
    sl_ssh_auth_method: []const u8,
    sl_ssh_identity_file: []const u8,
    sl_mode_chat: []const u8,
    sl_default_suffix: []const u8,

    // —— 命令面板 chrome ——
    cmd_palette_title: []const u8,
    cmd_palette_history_title: []const u8,
    cmd_palette_esc_closes: []const u8,
    cmd_palette_esc_returns: []const u8,
    cmd_palette_filter_placeholder: []const u8,
    cmd_palette_no_sessions_yet: []const u8,
    cmd_palette_recent_sessions: []const u8,
    cmd_palette_no_sessions: []const u8,
    cmd_palette_footer: []const u8,
    cmd_palette_footer_history: []const u8,
    copilot_picker_title: []const u8,
    copilot_picker_new: []const u8,
    copilot_picker_empty: []const u8,

    // —— 状态 Toast ——
    toast_enable_weixin_first: []const u8,
    toast_wechat_login_failed: []const u8,
    toast_wechat_poller_already_running: []const u8,
    toast_wechat_start_failed: []const u8,
    toast_wechat_binding_saved_stopped: []const u8,
    toast_wechat_not_active: []const u8,
    toast_wechat_login_waiting: []const u8,
    toast_wechat_poller_already_stopped: []const u8,
    toast_wechat_unbind_failed: []const u8,
    toast_wechat_unbound: []const u8,
    toast_copied_prefix: []const u8,
    toast_copied_bytes_suffix: []const u8,

    // —— 传输 Toast 动词 ——
    tt_downloading: []const u8,
    tt_downloaded: []const u8,
    tt_download_failed: []const u8,
    tt_download_interrupted: []const u8,
    tt_download: []const u8,
    tt_uploading: []const u8,
    tt_uploaded: []const u8,
    tt_upload_failed: []const u8,
    tt_upload_interrupted: []const u8,
    tt_upload: []const u8,

    // —— 键盘快捷键浮层 ——
    shortcuts_heading: []const u8,
    shortcuts_hint: []const u8,
    shortcuts_unbound: []const u8,
};

const en = Strings{
    .language_name = "English",
    .toast_wechat_not_connected = "WeChat not connected",
    .toast_wechat_poller_started = "WeChat poller started",
    .toast_wechat_poller_stopped = "WeChat poller stopped",
    .toast_wechat_direct_disabled = "WeChat direct disabled",

    .settings_title = "Settings",
    .settings_subtitle = "Config changes save immediately",
    .settings_font_size = "Font size",
    .settings_theme = "Theme",
    .settings_cursor_style = "Cursor style",
    .settings_cursor_blink = "Cursor blink",
    .settings_focus_follows_mouse = "Focus follows mouse",
    .settings_restore_tabs = "Restore tabs on startup",
    .settings_shell = "Shell for new tabs",
    .settings_default_ai = "Default AI",
    .settings_weixin_direct = "WeChat direct",
    .settings_distill_suggest = "Distill skill suggestions",
    .settings_language = "Language",
    .settings_raw_config = "Raw config file",
    .settings_restore_defaults = "Restore default settings",
    .settings_close = "Close settings",
    .restore_defaults_title = "Restore default settings?",
    .restore_defaults_body = "Settings on this page revert to defaults. AI profiles, keybinds, and other config are kept.",
    .restore_defaults_hint = "Press Esc or Cancel to keep your settings.",
    .restore_defaults_apply = "Restore",
    .restore_defaults_cancel = "Cancel",
    .settings_hint_advanced_editor = "Advanced editor",
    .settings_hint_add_profiles = "Add profiles via Command Center",
    .settings_hint_restart = "restart to apply",
    .settings_value_on = "on",
    .settings_value_off = "off",
    .settings_value_open = "open",
    .settings_value_none = "(none)",
    .settings_lang_auto = "Auto",

    .sl_new_session = "New Session",
    .sl_ai_agent = "Copilot",
    .sl_sessions = "Sessions",
    .sl_sessions_detail = "Browse Codex / Claude Code sessions",
    .sl_skill_center = "Skill Center",
    .sl_skill_center_detail = "Manage Claude Code / Codex skills and local executable tools",
    .pf_title = "Port Forwarding",
    .pf_detail = "Manage SSH port forwarding rules",
    .pf_legend = "[n] new   [e] edit   [space] start/stop   [r] restart   [a] auto   [d] delete   [esc] close/cancel",
    .pf_form_legend = "[up/down] move   [left/right/space] change   [enter] save   [esc] cancel",

    .sc_local = "Local",
    .sc_wsl = "WSL",
    .sc_scanning = "No skills found. Scanning…",
    .sc_no_server = "(no server)",
    .sc_cached = "(cached)",
    .sc_offline = "(offline)",
    .sc_hint_same = "in sync",
    .sc_hint_differ = "differs → diff / overwrite",
    .sc_hint_local_only = "local only → upload",
    .sc_hint_remote_only = "remote only → download",
    .sc_hint_unknown = "can't verify",
    .sc_legend = "✓ exists   ≠ differs   — absent   ? unknown      [⏎] preview/diff   [u] upload   [d] download   [s] switch server",
    .sc_toast_synced = "Skill synced",
    .sc_toast_sync_failed = "Skill sync failed",
    .sc_busy_syncing = "Syncing…",
    .sc_toast_op_busy = "A sync is already running",
    .sc_toast_sync_failed_prefix = "Sync failed: ",
    .sc_toast_in_sync = "Already in sync",
    .sc_toast_no_local = "No local copy of this skill",
    .sc_toast_no_remote = "Server has no copy of this skill",
    .sc_toast_no_conn = "Can't connect to the selected server",
    .sc_toast_read_failed = "Couldn't read SKILL.md",
    .sc_overwrite_upload = "Overwrite upload of",
    .sc_overwrite_download = "Overwrite download of",
    .sc_confirm_suffix = "— content differs. [⏎] confirm  [esc] cancel",

    .sc_legend_v2 = "[space] preview   [↵] deploy   [i] import   [t] import tool   [e] enable   [g] get   [r] rescan",
    .sc_legend_import = "[space] preview   [↵] import   [esc] back",
    .sc_busy_loading = "Loading…",
    .sc_tool_import_failed = "Tool import is not available yet",
    .sc_tool_toggle_failed = "Tool enable state could not be updated",
    .sc_tool_enabled = "Tool enabled",
    .sc_tool_disabled = "Tool disabled",
    .sc_pick_deploy = "Deploy to…  (↑/↓ + ⏎, esc to cancel)",
    .sc_pick_import = "Import from…  (↑/↓ + ⏎, esc to cancel)",
    .sc_import_title = "Pick a skill to import  (↑/↓ + ⏎, esc to cancel)",
    .sc_sw_claude = "Claude Code",
    .sc_sw_codex = "Codex",
    .sc_marker_new = "new",
    .sc_marker_same = "same",
    .sc_marker_differ = "differs",
    .sc_toast_imported = "Skill imported",
    .sc_empty = "No library skills yet — press [i] to import some.",
    .sc_url_prompt = "Paste a GitHub skills URL, then ↵   (esc to cancel)",
    .sc_pick_install = "Select skills to install   ([space] toggle  [a] all  [↵] install  esc cancel)",
    .sc_preview_hint = "esc/space close   ↑/↓ PgUp/PgDn scroll",
    .sc_busy_fetching = "Fetching…",
    .sc_busy_installing = "Installing…",
    .sc_toast_installed = "Skills installed",
    .sc_toast_install_partial = "Some skills failed to install",
    .sc_toast_no_skills = "No skills found at that URL",
    .sc_toast_bad_url = "Couldn't parse that GitHub URL",
    .sc_toast_truncated = "Repo is large — the skill list may be incomplete",

    .sl_llm_providers = "LLM Providers",
    .sl_new_llm_provider = "New LLM Provider",
    .sl_edit_llm_provider = "Edit LLM Provider",
    .sl_delete_llm_provider = "Delete LLM Provider",
    .sl_ssh_server = "SSH Server",
    .sl_ssh_servers = "SSH Servers",
    .sl_new_ssh_server = "New SSH Server",
    .sl_edit_ssh_server = "Edit SSH Server",
    .sl_delete_ssh_server = "Delete SSH Server",
    .sl_cancel = "Cancel",
    .sl_save = "Save",
    .sl_back = "Back",
    .sl_save_open = "Save & Open",
    .sl_save_connect = "Save & Connect",
    .sl_v_add = "add",
    .sl_v_choose = "choose",
    .sl_v_no_profile = "no profile",
    .sl_v_no_server = "no server",
    .sl_v_manage = "manage",
    .sl_v_profile = "profile",
    .sl_v_agent = "agent",
    .sl_v_connect_server = "connect server",
    .sl_hint_main = "Up/Down select, Enter starts",
    .sl_hint_ai_form = "Configure once, then Enter opens",
    .sl_hint_ai_manage = "Enter opens, New/Edit/Delete manage",
    .sl_hint_choose_profile_edit = "Choose a profile to edit",
    .sl_hint_choose_profile_delete = "Choose a profile to delete",
    .sl_hint_ssh_form = "Tab changes field, Enter connects",
    .sl_hint_ssh_filter_edits = "Type to filter, Backspace edits, Enter connects",
    .sl_hint_ssh_filter_manage = "Type to filter, Enter connects, New/Edit/Delete manage",
    .sl_hint_ssh_filter_choose_edit = "Type to filter, Choose a server to edit",
    .sl_hint_choose_server_edit = "Choose a server to edit",
    .sl_hint_ssh_filter_choose_delete = "Type to filter, Choose a server to delete",
    .sl_hint_choose_server_delete = "Choose a server to delete",
    .sl_ai_profile_name = "Profile name",
    .sl_ai_base_url = "Base URL",
    .sl_ai_api_key = "API key",
    .sl_switch_model_title = "Switch Model",
    .sl_switch_model_hint = "Choose a profile, or Esc to cancel",
    .ai_summary_card_title = "Conversation summary",
    .ai_model_no_profiles = "No AI profiles configured. Add one in Settings → AI profiles.",
    .ai_model_unknown_profile = "No AI profile by that name; choose one from the list.",
    .sl_ai_model = "Model",
    .sl_ai_system = "System",
    .sl_ai_thinking = "Thinking",
    .sl_ai_effort = "Effort",
    .sl_ai_stream = "Stream",
    .sl_ai_agent_field = "Agent",
    .sl_ai_protocol = "Protocol",
    .sl_ai_max_tokens = "Max Tokens",
    .sl_ai_vision = "Vision",
    .sl_ssh_server_name = "Server name",
    .sl_ssh_ip_host = "IP / host",
    .sl_ssh_user = "User",
    .sl_ssh_password = "Password",
    .sl_ssh_port = "Port",
    .sl_ssh_jump_host = "Jump host",
    .sl_ssh_auth_method = "Auth method",
    .sl_ssh_identity_file = "Identity file",
    .sl_mode_chat = "Chat",
    .sl_default_suffix = " (default)",

    .cmd_palette_title = "Command Center",
    .cmd_palette_history_title = "Copilot History",
    .cmd_palette_esc_closes = "Esc closes",
    .cmd_palette_esc_returns = "Esc returns",
    .cmd_palette_filter_placeholder = "Filter commands or themes",
    .cmd_palette_no_sessions_yet = "No saved Copilot sessions yet",
    .cmd_palette_recent_sessions = "Recent Copilot sessions",
    .cmd_palette_no_sessions = "No saved Copilot sessions",
    .cmd_palette_footer = "Up/Down + Enter applies",
    .cmd_palette_footer_history = "Up/Down selects, Enter reopens, Delete removes, Esc returns",
    .copilot_picker_title = "Copilot conversations (Up/Down, Enter, Delete, Esc)",
    .copilot_picker_new = "+ New conversation",
    .copilot_picker_empty = "No saved Copilot conversations",

    .toast_enable_weixin_first = "Enable weixin-direct-enabled first, then restart WispTerm",
    .toast_wechat_login_failed = "WeChat login failed to start",
    .toast_wechat_poller_already_running = "WeChat poller already running",
    .toast_wechat_start_failed = "WeChat start failed",
    .toast_wechat_binding_saved_stopped = "WeChat binding saved; poller stopped",
    .toast_wechat_not_active = "WeChat direct is not active",
    .toast_wechat_login_waiting = "WeChat login is still waiting",
    .toast_wechat_poller_already_stopped = "WeChat poller already stopped",
    .toast_wechat_unbind_failed = "WeChat unbind failed",
    .toast_wechat_unbound = "WeChat unbound",
    .toast_copied_prefix = "Copied (",
    .toast_copied_bytes_suffix = " bytes)",

    .tt_downloading = "Downloading",
    .tt_downloaded = "Downloaded",
    .tt_download_failed = "Download failed",
    .tt_download_interrupted = "Download interrupted",
    .tt_download = "Download",
    .tt_uploading = "Uploading",
    .tt_uploaded = "Uploaded",
    .tt_upload_failed = "Upload failed",
    .tt_upload_interrupted = "Upload interrupted",
    .tt_upload = "Upload",

    .shortcuts_heading = "Keyboard shortcuts",
    .shortcuts_hint = "Press any key or click to hide",
    .shortcuts_unbound = "unbound",
};

const zh_CN = Strings{
    .language_name = "中文",
    .toast_wechat_not_connected = "微信未连接",
    .toast_wechat_poller_started = "微信轮询已启动",
    .toast_wechat_poller_stopped = "微信轮询已停止",
    .toast_wechat_direct_disabled = "微信直连已禁用",

    .settings_title = "设置",
    .settings_subtitle = "配置更改立即保存",
    .settings_font_size = "字号",
    .settings_theme = "主题",
    .settings_cursor_style = "光标样式",
    .settings_cursor_blink = "光标闪烁",
    .settings_focus_follows_mouse = "焦点跟随鼠标",
    .settings_restore_tabs = "启动时恢复标签页",
    .settings_shell = "新标签页 Shell",
    .settings_default_ai = "默认 AI",
    .settings_weixin_direct = "微信直连",
    .settings_distill_suggest = "技能沉淀建议",
    .settings_language = "语言",
    .settings_raw_config = "原始配置文件",
    .settings_restore_defaults = "恢复默认设置",
    .settings_close = "关闭设置",
    .restore_defaults_title = "恢复默认设置？",
    .restore_defaults_body = "本页设置将恢复为默认值。AI 配置、快捷键等其他配置会保留。",
    .restore_defaults_hint = "按 Esc 或取消以保留当前设置。",
    .restore_defaults_apply = "恢复默认",
    .restore_defaults_cancel = "取消",
    .settings_hint_advanced_editor = "高级编辑器",
    .settings_hint_add_profiles = "在命令中心添加配置",
    .settings_hint_restart = "重启生效",
    .settings_value_on = "开",
    .settings_value_off = "关",
    .settings_value_open = "打开",
    .settings_value_none = "（无）",
    .settings_lang_auto = "自动",

    .sl_new_session = "新建会话",
    .sl_ai_agent = "副驾",
    .sl_sessions = "会话",
    .sl_sessions_detail = "浏览 Codex / Claude Code 会话",
    .sl_skill_center = "技能中心",
    .sl_skill_center_detail = "管理 Claude Code / Codex 技能和本地可执行工具",
    .pf_title = "端口转发",
    .pf_detail = "管理 SSH 端口转发规则",
    .pf_legend = "[n] 新建   [e] 编辑   [space] 启停   [r] 重启   [a] 自动启动   [d] 删除   [esc] 关闭/取消",
    .pf_form_legend = "[上/下] 切换字段   [左/右 或 空格] 切换选项   [enter] 保存   [esc] 取消",

    .sc_local = "本地",
    .sc_wsl = "WSL",
    .sc_scanning = "未发现技能，扫描中…",
    .sc_no_server = "（无服务器）",
    .sc_cached = "（缓存）",
    .sc_offline = "（离线）",
    .sc_hint_same = "已一致",
    .sc_hint_differ = "不同 → 对比 / 覆盖",
    .sc_hint_local_only = "仅本地 → 可上传",
    .sc_hint_remote_only = "仅远程 → 可下载",
    .sc_hint_unknown = "无法校验",
    .sc_legend = "✓ 存在   ≠ 内容不同   — 不存在   ? 无法校验      [⏎] 预览/对比   [u] 上传   [d] 下载   [s] 换服务器",
    .sc_toast_synced = "技能已同步",
    .sc_toast_sync_failed = "技能同步失败",
    .sc_busy_syncing = "同步中…",
    .sc_toast_op_busy = "同步进行中",
    .sc_toast_sync_failed_prefix = "同步失败: ",
    .sc_toast_in_sync = "已一致，无需同步",
    .sc_toast_no_local = "本地没有该技能",
    .sc_toast_no_remote = "服务器没有该技能",
    .sc_toast_no_conn = "无法连接所选服务器",
    .sc_toast_read_failed = "无法读取 SKILL.md",
    .sc_overwrite_upload = "上传覆盖",
    .sc_overwrite_download = "下载覆盖",
    .sc_confirm_suffix = "（内容不同）。 [⏎] 确认  [esc] 取消",

    .sc_legend_v2 = "[space] 预览   [↵] 部署   [i] 导入   [t] 导入工具   [e] 启用   [g] 获取   [r] 重新扫描",
    .sc_legend_import = "[space] 预览   [↵] 导入   [esc] 返回",
    .sc_busy_loading = "加载中…",
    .sc_tool_import_failed = "工具导入暂不可用",
    .sc_tool_toggle_failed = "无法更新工具启用状态",
    .sc_tool_enabled = "工具已启用",
    .sc_tool_disabled = "工具已禁用",
    .sc_pick_deploy = "部署到…  (↑/↓ + ⏎，esc 取消)",
    .sc_pick_import = "从哪里导入…  (↑/↓ + ⏎，esc 取消)",
    .sc_import_title = "选择要导入的技能  (↑/↓ + ⏎，esc 取消)",
    .sc_sw_claude = "Claude Code",
    .sc_sw_codex = "Codex",
    .sc_marker_new = "新增",
    .sc_marker_same = "一致",
    .sc_marker_differ = "不同",
    .sc_toast_imported = "技能已导入",
    .sc_empty = "库中暂无技能 —— 按 [i] 导入。",
    .sc_url_prompt = "粘贴 GitHub 技能链接，然后按 ↵   (esc 取消)",
    .sc_pick_install = "选择要安装的技能   ([space] 选择  [a] 全选  [↵] 安装  esc 取消)",
    .sc_preview_hint = "esc/space 关闭   ↑/↓ PgUp/PgDn 滚动",
    .sc_busy_fetching = "获取中…",
    .sc_busy_installing = "安装中…",
    .sc_toast_installed = "技能已安装",
    .sc_toast_install_partial = "部分技能安装失败",
    .sc_toast_no_skills = "该链接下未找到技能",
    .sc_toast_bad_url = "无法解析该 GitHub 链接",
    .sc_toast_truncated = "仓库较大 —— 技能列表可能不完整",

    .sl_llm_providers = "LLM 提供方",
    .sl_new_llm_provider = "新建 LLM 提供方",
    .sl_edit_llm_provider = "编辑 LLM 提供方",
    .sl_delete_llm_provider = "删除 LLM 提供方",
    .sl_ssh_server = "SSH 服务器",
    .sl_ssh_servers = "SSH 服务器",
    .sl_new_ssh_server = "新建 SSH 服务器",
    .sl_edit_ssh_server = "编辑 SSH 服务器",
    .sl_delete_ssh_server = "删除 SSH 服务器",
    .sl_cancel = "取消",
    .sl_save = "保存",
    .sl_back = "返回",
    .sl_save_open = "保存并打开",
    .sl_save_connect = "保存并连接",
    .sl_v_add = "新建",
    .sl_v_choose = "选择",
    .sl_v_no_profile = "无配置",
    .sl_v_no_server = "无服务器",
    .sl_v_manage = "管理",
    .sl_v_profile = "配置",
    .sl_v_agent = "智能体",
    .sl_v_connect_server = "连接服务器",
    .sl_hint_main = "上下选择，回车启动",
    .sl_hint_ai_form = "配置一次，回车即打开",
    .sl_hint_ai_manage = "回车打开，新建/编辑/删除可管理",
    .sl_hint_choose_profile_edit = "选择要编辑的配置",
    .sl_hint_choose_profile_delete = "选择要删除的配置",
    .sl_hint_ssh_form = "Tab 切换字段，回车连接",
    .sl_hint_ssh_filter_edits = "输入可筛选，Backspace 编辑，回车连接",
    .sl_hint_ssh_filter_manage = "输入可筛选，回车连接，新建/编辑/删除可管理",
    .sl_hint_ssh_filter_choose_edit = "输入可筛选，选择要编辑的服务器",
    .sl_hint_choose_server_edit = "选择要编辑的服务器",
    .sl_hint_ssh_filter_choose_delete = "输入可筛选，选择要删除的服务器",
    .sl_hint_choose_server_delete = "选择要删除的服务器",
    .sl_ai_profile_name = "配置名称",
    .sl_ai_base_url = "接口地址",
    .sl_ai_api_key = "API 密钥",
    .sl_switch_model_title = "切换模型",
    .sl_switch_model_hint = "选择一个配置，或按 Esc 取消",
    .ai_summary_card_title = "上文摘要",
    .ai_model_no_profiles = "尚未配置 AI 配置。请在 设置 → AI 配置 中新建。",
    .ai_model_unknown_profile = "没有同名的 AI 配置，请从列表中选择。",
    .sl_ai_model = "模型",
    .sl_ai_system = "系统提示",
    .sl_ai_thinking = "思考",
    .sl_ai_effort = "推理强度",
    .sl_ai_stream = "流式",
    .sl_ai_agent_field = "智能体",
    .sl_ai_protocol = "协议",
    .sl_ai_max_tokens = "最大 Token",
    .sl_ai_vision = "视觉",
    .sl_ssh_server_name = "服务器名称",
    .sl_ssh_ip_host = "IP / 主机",
    .sl_ssh_user = "用户",
    .sl_ssh_password = "密码",
    .sl_ssh_port = "端口",
    .sl_ssh_jump_host = "跳板机",
    .sl_ssh_auth_method = "认证方式",
    .sl_ssh_identity_file = "密钥文件",
    .sl_mode_chat = "对话",
    .sl_default_suffix = "（默认）",

    .cmd_palette_title = "命令中心",
    .cmd_palette_history_title = "副驾历史",
    .cmd_palette_esc_closes = "Esc 关闭",
    .cmd_palette_esc_returns = "Esc 返回",
    .cmd_palette_filter_placeholder = "筛选命令或主题",
    .cmd_palette_no_sessions_yet = "暂无已保存的副驾会话",
    .cmd_palette_recent_sessions = "最近的副驾会话",
    .cmd_palette_no_sessions = "没有已保存的副驾会话",
    .cmd_palette_footer = "上下选择，回车执行",
    .cmd_palette_footer_history = "上下选择，回车重开，Delete 删除，Esc 返回",
    .copilot_picker_title = "副驾对话（上下选择，回车打开，Delete 删除，Esc 关闭）",
    .copilot_picker_new = "+ 新建对话",
    .copilot_picker_empty = "没有已保存的副驾对话",

    .toast_enable_weixin_first = "请先启用 weixin-direct-enabled，然后重启 WispTerm",
    .toast_wechat_login_failed = "微信登录启动失败",
    .toast_wechat_poller_already_running = "微信轮询已在运行",
    .toast_wechat_start_failed = "微信启动失败",
    .toast_wechat_binding_saved_stopped = "已保存微信绑定；轮询已停止",
    .toast_wechat_not_active = "微信直连未激活",
    .toast_wechat_login_waiting = "微信登录仍在等待",
    .toast_wechat_poller_already_stopped = "微信轮询本就已停止",
    .toast_wechat_unbind_failed = "微信解绑失败",
    .toast_wechat_unbound = "微信已解绑",
    .toast_copied_prefix = "已复制（",
    .toast_copied_bytes_suffix = " 字节）",

    .tt_downloading = "正在下载",
    .tt_downloaded = "已下载",
    .tt_download_failed = "下载失败",
    .tt_download_interrupted = "下载中断",
    .tt_download = "下载",
    .tt_uploading = "正在上传",
    .tt_uploaded = "已上传",
    .tt_upload_failed = "上传失败",
    .tt_upload_interrupted = "上传中断",
    .tt_upload = "上传",

    .shortcuts_heading = "键盘快捷键",
    .shortcuts_hint = "按任意键或点击隐藏",
    .shortcuts_unbound = "未绑定",
};

// Set once at startup before any UI thread exists (see main.zig startup wiring).
// Not thread-safe; do not call setLang after App.init.
var current: *const Strings = &en;
var active_lang: Lang = .en;

/// 当前语言的文案表。调用点：`i18n.s().language_name`。
pub fn s() *const Strings {
    return current;
}

pub fn lang() Lang {
    return active_lang;
}

pub fn setLang(l: Lang) void {
    active_lang = l;
    current = switch (l) {
        .en => &en,
        .zh_CN => &zh_CN,
    };
}

/// config `language` 取值。auto = 跟随系统 locale。
pub const LanguageSetting = enum {
    auto,
    en,
    zh_CN,

    /// 解析 config 值；大小写/分隔符兼容；未知返回 null。
    pub fn parse(value: []const u8) ?LanguageSetting {
        var buf: [16]u8 = undefined;
        if (value.len > buf.len) return null;
        for (value, 0..) |c, i| {
            buf[i] = switch (c) {
                'A'...'Z' => c + 32, // tolower
                '_' => '-',
                else => c,
            };
        }
        const v = buf[0..value.len];
        if (std.mem.eql(u8, v, "auto")) return .auto;
        if (std.mem.eql(u8, v, "en")) return .en;
        if (std.mem.eql(u8, v, "zh-cn") or std.mem.eql(u8, v, "zh")) return .zh_CN;
        return null;
    }
};

/// 把 locale 标签（如 "zh_CN.UTF-8" / "en_US" / "zh"）映射到支持的语言。
/// 以 "zh" 开头（不分大小写）→ zh_CN；其余 → en。
/// 注意：这里对 `zh*` 是宽松前缀匹配（自动检测应尽量识别中文，含 zh_TW），
/// 与 `LanguageSetting.parse` 的严格匹配（显式 `zh-TW` 视为非法并告警）有意不同。
pub fn langFromLocaleTag(tag: []const u8) Lang {
    if (tag.len >= 2) {
        const a = tag[0];
        const b = tag[1];
        const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
        const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
        if (la == 'z' and lb == 'h') return .zh_CN;
    }
    return .en;
}

// Windows 在 env 缺失 LANG/LC_* 时，从用户界面语言（LANGID）兜底。
// 主语言号 = LANGID & 0x3FF；LANG_CHINESE = 0x04。仅由 Windows 构建验证，
// 原生（Linux）测试不覆盖此分支。
extern "kernel32" fn GetUserDefaultUILanguage() callconv(.winapi) u16;

/// 读系统 locale 环境变量（LC_ALL → LC_MESSAGES → LANG），映射到语言。
/// 都读不到时：Windows 回落到 GetUserDefaultUILanguage，其余平台 → en。
/// 调用方提供 allocator；本函数内部释放临时串。
pub fn detectSystemLang(allocator: std.mem.Allocator) Lang {
    const vars = [_][]const u8{ "LC_ALL", "LC_MESSAGES", "LANG" };
    for (vars) |name| {
        const val = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
            error.OutOfMemory => return .en, // allocator exhausted; safe fallback
            else => continue, // missing var / invalid encoding → try next
        };
        defer allocator.free(val);
        if (val.len == 0) continue;
        return langFromLocaleTag(val);
    }
    if (builtin.os.tag == .windows) {
        if ((GetUserDefaultUILanguage() & 0x3ff) == 0x04) return .zh_CN; // LANG_CHINESE
    }
    return .en;
}

/// 按优先级解析最终语言：config 显式值优先；auto 跟随系统 locale；
/// 任何不可解析情形回退 en。
pub fn resolve(allocator: std.mem.Allocator, setting: LanguageSetting) Lang {
    return switch (setting) {
        .en => .en,
        .zh_CN => .zh_CN,
        .auto => detectSystemLang(allocator),
    };
}

/// 启动时调用一次：解析 config 的 language 设定并设置当前语言。
pub fn applyConfig(allocator: std.mem.Allocator, setting: LanguageSetting) void {
    setLang(resolve(allocator, setting));
}

/// 命令中心标题的本地化覆盖。en（及未来源语言）返回 null，调用点用英文原表值。
pub fn commandTitle(action: CommandAction) ?[]const u8 {
    if (active_lang != .zh_CN) return null;
    return switch (action) {
        .new_tab => "新建会话",
        .load_openssh_config => "导入 OpenSSH 配置",
        .new_agent => "新建副驾",
        .toggle_ai_copilot => "开 / 关 Copilot",
        .manage_ai_profiles => "管理 AI 配置",
        .select_agent_history => "选择副驾历史",
        .split_right => "向右分屏",
        .split_down => "向下分屏",
        .split_left => "向左分屏",
        .split_up => "向上分屏",
        .focus_previous => "上一个面板",
        .focus_next => "下一个面板",
        .equalize_splits => "均分面板",
        .close_split_or_tab => "关闭面板 / 标签页",
        .toggle_sidebar => "切换侧边栏",
        .toggle_file_explorer => "切换文件浏览器",
        .toggle_browser_panel => "切换浏览器",
        .open_jupyter_panel => "打开 Jupyter",
        .toggle_quake => "切换下拉终端",
        .open_settings => "设置",
        .show_shortcuts => "键盘快捷键",
        .open_config => "打开配置文件",
        .font_size_decrease => "减小字号",
        .font_size_increase => "增大字号",
        .toggle_maximize => "切换最大化",
        .copy_remote_key => "复制远程密钥",
        .connect_wechat => "连接微信",
        .start_wechat => "微信：启动",
        .stop_wechat => "微信：停止",
        .wechat_status => "微信：状态",
        .unbind_wechat => "微信：解绑",
        .export_ai_chat_markdown => "导出副驾 Markdown",
        .export_ai_chat_markdown_clean => "导出副驾 Markdown 精简版",
        .show_version => "版本",
        .check_for_updates => "检查更新",
        .download_update => "下载更新",
        .open_latest_release => "打开最新发布",
        .show_whats_new => "更新内容",
        .install_claude_code_integration => "安装 Claude Code 集成",
        .remove_claude_code_integration => "移除 Claude Code 集成",
        .open_skill_center => "技能中心",
        .open_port_forwarding => "端口转发",
        .split_preview => "分屏预览",
    };
}

/// 命令中心详情的本地化覆盖。约定同 commandTitle。
/// 注意：命令面板当前只渲染 title，不渲染 detail —— 这些译文仅用于过滤匹配
///（让 zh 用户能用中文搜索命中），UI 上不直接显示。
pub fn commandDetail(action: CommandAction) ?[]const u8 {
    if (active_lang != .zh_CN) return null;
    return switch (action) {
        .new_tab => "选择 Shell、SSH、WSL、副驾 或 会话",
        .load_openssh_config => "把 ~/.ssh/config 导入为 SSH profile",
        .new_agent => "用默认 AI 配置打开一个新的副驾标签页",
        .toggle_ai_copilot => "在当前终端上打开或关闭 Copilot 侧栏",
        .manage_ai_profiles => "创建、编辑或删除已保存的 AI 配置",
        .select_agent_history => "打开命令中心的副驾历史选择器",
        .split_right => "在右侧创建一个面板",
        .split_down => "在下方创建一个面板",
        .split_left => "在左侧创建一个面板",
        .split_up => "在上方创建一个面板",
        .focus_previous => "把焦点移到上一个面板",
        .focus_next => "把焦点移到下一个面板",
        .equalize_splits => "重置当前标签页的分屏大小",
        .close_split_or_tab => "关闭当前面板或标签页；再按一次关闭最后一个面板",
        .toggle_sidebar => "显示或隐藏标签页侧边栏",
        .toggle_file_explorer => "显示或隐藏左侧文件浏览器",
        .toggle_browser_panel => "为本地或 SSH 网址打开已配置的浏览器",
        .open_jupyter_panel => "打开面板并粘贴正在运行的 Jupyter 网址（本地或 SSH）",
        .toggle_quake => "显示或隐藏下拉式终端窗口",
        .open_settings => "打开设置页",
        .show_shortcuts => "显示快捷键参考浮层",
        .open_config => "打开 WispTerm 配置文件",
        .font_size_decrease => "把终端文字调小",
        .font_size_increase => "把终端文字调大",
        .toggle_maximize => "最大化或还原窗口",
        .copy_remote_key => "复制当前 WispTerm 远程会话密钥",
        .connect_wechat => "扫码连接微信直连控制",
        .start_wechat => "用已保存的微信绑定开始轮询",
        .stop_wechat => "停止轮询并保留已保存的微信绑定",
        .wechat_status => "显示微信直连连接状态",
        .unbind_wechat => "清除已存储的微信直连绑定",
        .export_ai_chat_markdown => "把当前 AI 对话保存为 Markdown",
        .export_ai_chat_markdown_clean => "保存用户提问与最终回答（不含思考过程）",
        .show_version => "显示 WispTerm 版本",
        .check_for_updates => "在 GitHub Releases 检查是否有新版本",
        .download_update => "把最新更新下载到「下载」文件夹",
        .open_latest_release => "打开最新的 WispTerm GitHub Release",
        .show_whats_new => "查看本版本的更新内容",
        .install_claude_code_integration => "将 WispTerm 智能体钩子添加到 ~/.claude/settings.json",
        .remove_claude_code_integration => "从 ~/.claude/settings.json 中移除 WispTerm 智能体钩子",
        .open_skill_center => "盘点各服务器上的 Claude Code / Codex 技能",
        .open_port_forwarding => "管理 SSH 端口转发规则",
        .split_preview => "在右侧打开预览面板",
    };
}

test "commandTitle/Detail: null on en, zh string on zh_CN" {
    defer setLang(.en);
    setLang(.en);
    try std.testing.expect(commandTitle(.open_settings) == null);
    try std.testing.expect(commandDetail(.open_settings) == null);
    setLang(.zh_CN);
    try std.testing.expectEqualStrings("设置", commandTitle(.open_settings).?);
    try std.testing.expectEqualStrings("打开设置页", commandDetail(.open_settings).?);
}

test "setLang switches the active strings table" {
    defer setLang(.en); // 复位，避免污染其它测试
    setLang(.en);
    try std.testing.expectEqualStrings("English", s().language_name);
    try std.testing.expect(lang() == .en);
    setLang(.zh_CN);
    try std.testing.expectEqualStrings("中文", s().language_name);
    try std.testing.expect(lang() == .zh_CN);
}

test "langFromLocaleTag maps zh* to zh_CN, others to en" {
    try std.testing.expect(langFromLocaleTag("zh_CN.UTF-8") == .zh_CN);
    try std.testing.expect(langFromLocaleTag("zh") == .zh_CN);
    try std.testing.expect(langFromLocaleTag("ZH-cn") == .zh_CN);
    try std.testing.expect(langFromLocaleTag("zh_TW") == .zh_CN); // v1 唯一中文落点
    try std.testing.expect(langFromLocaleTag("en_US.UTF-8") == .en);
    try std.testing.expect(langFromLocaleTag("fr") == .en);
    try std.testing.expect(langFromLocaleTag("") == .en);
    try std.testing.expect(langFromLocaleTag("z") == .en);
}

test "LanguageSetting.parse handles aliases and invalid" {
    try std.testing.expect(LanguageSetting.parse("auto").? == .auto);
    try std.testing.expect(LanguageSetting.parse("en").? == .en);
    try std.testing.expect(LanguageSetting.parse("zh-CN").? == .zh_CN);
    try std.testing.expect(LanguageSetting.parse("zh_CN").? == .zh_CN);
    try std.testing.expect(LanguageSetting.parse("ZH").? == .zh_CN);
    try std.testing.expect(LanguageSetting.parse("de") == null);
    try std.testing.expect(LanguageSetting.parse("") == null);
}

test "applyConfig sets active language" {
    const a = std.testing.allocator;
    defer setLang(.en);
    applyConfig(a, .zh_CN);
    try std.testing.expect(lang() == .zh_CN);
    applyConfig(a, .en);
    try std.testing.expect(lang() == .en);
}

test "resolve: explicit setting beats system; auto follows env-mapping" {
    const a = std.testing.allocator;
    try std.testing.expect(resolve(a, .en) == .en);
    try std.testing.expect(resolve(a, .zh_CN) == .zh_CN);
    // auto 取决于运行环境 env，至少应返回二者之一且不崩溃。
    const auto = resolve(a, .auto);
    try std.testing.expect(auto == .en or auto == .zh_CN);
}

test "toast strings: en source and zh translation both present" {
    defer setLang(.en);
    setLang(.en);
    try std.testing.expectEqualStrings("WeChat not connected", s().toast_wechat_not_connected);
    setLang(.zh_CN);
    try std.testing.expectEqualStrings("微信未连接", s().toast_wechat_not_connected);
    try std.testing.expectEqualStrings("微信轮询已启动", s().toast_wechat_poller_started);
    try std.testing.expectEqualStrings("微信轮询已停止", s().toast_wechat_poller_stopped);
    try std.testing.expectEqualStrings("微信直连已禁用", s().toast_wechat_direct_disabled);
}

test "settings strings: en source and zh translation present" {
    defer setLang(.en);
    setLang(.en);
    try std.testing.expectEqualStrings("Settings", s().settings_title);
    try std.testing.expectEqualStrings("Language", s().settings_language);
    setLang(.zh_CN);
    try std.testing.expectEqualStrings("设置", s().settings_title);
    try std.testing.expectEqualStrings("语言", s().settings_language);
    try std.testing.expectEqualStrings("重启生效", s().settings_hint_restart);
    try std.testing.expect(s().settings_close.len > 0);
}
