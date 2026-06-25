//! Source guards for the P3.1/P3.1b AppWindow extraction boundaries.

const std = @import("std");

const appwindow_source = @embedFile("../AppWindow.zig");

const remote_sync_markers = [_][]const u8{
    "fn buildRemoteLayoutJson",
    "fn buildLayoutJson",
    "fn appendLayoutJson",
    "const RemoteAiInputRequest",
    "const RemoteAiAgentOpenRequest",
    "fn registerRemoteAiInputSink",
    "fn writeAiInput",
    "fn remoteAiWrite",
    "fn remoteAiAgentOpen",
    "fn appendRemoteAiChatTabJson",
    "fn appendRemoteAiHistoryTabJson",
    "fn handleAiInputRequest",
    "fn handleAiAgentOpenRequest",
};

const control_api_markers = [_][]const u8{
    "fn buildCtlPanesJson",
    "const ctl_vtable",
    "fn ctlListPanes",
    "fn ctlGetText",
    "fn ctlSendText",
    "fn ctlUiState",
    "fn appendPanesJson",
    "var g_agent_control_enabled",
    "var g_ctl_",
};

const surface_snapshot_markers = [_][]const u8{
    "fn makeAgentToolSurface",
    "fn findAgentSurfaceLocation",
    "fn collectAgentToolSnapshot",
    "fn agentSurfaceSnapshot",
    "fn agentWriteSurface",
    "fn agentSshConnectionForSurface",
};

const weixin_bridge_markers = [_][]const u8{
    "const WeixinRequest",
    "const weixin_vtable",
    "fn tabConversationSession",
    "fn weixinActiveAiTabIndex",
    "fn weixinTabIndexFromSurfaceId",
    "fn weixinActiveTerminalSurface",
    "fn weixinTerminalSurfaceFromId",
    "fn weixinDispatch",
    "fn weixinOpenAiPanel",
    "fn weixinAppendAiInput",
    "fn weixinSubmitAiPrompt",
    "fn weixinClearAiPanel",
    "fn weixinSendToTerminal",
    "fn weixinActiveSnapshot",
    "fn wxIsConnected",
    "fn wxFindAiSurface",
    "fn wxFindTerminalSurface",
    "fn wxOpenAiAgent",
    "fn wxOpenAiAgentProfile",
    "fn wxModelProfiles",
    "fn wxSwitchAiProfile",
    "fn wxSendInput",
    "fn wxTranscript",
    "fn wxInboundFileDir",
    "fn wxListAiConversations",
    "fn wxPinAiConversationByIndex",
    "fn wxAiApprovalPending",
    "fn wxAiQuestionOptionCount",
    "fn wxResolveAiQuestion",
    "fn wxResolveAiApproval",
    "var g_weixin_ui_handle",
    "var g_weixin_ctx",
    "var g_weixin_transcript_mutex",
    "var g_weixin_transcript_owned",
    "var g_weixin_pinned_session",
};

const agent_request_markers = [_][]const u8{
    "const AgentTabNewRequest",
    "const AgentTabCloseRequest",
    "const AgentSshConnectRequest",
    "const AgentSshSaveRequest",
    "fn postAgentRequest",
    "fn postAgentOwnedStringRequest",
    "fn postAgentTabNew",
    "fn postAgentTabClose",
    "fn postAgentSshConnect",
    "fn postAgentSshSave",
    "fn agentCloseTab",
    "fn agentConnectSshProfile",
    "fn agentSaveSshProfile",
    "fn agentSpawnTab",
    "fn agentTabCommand",
    "fn findTabIndexBySurfaceId",
    "fn findTabIndexByTitle",
    "fn resolveAgentCloseTabIndex",
    "fn handleAgentTabNewRequest",
    "fn handleAgentTabCloseRequest",
    "fn handleAgentSshConnectRequest",
    "fn handleAgentSshSaveRequest",
    "fn handleTabNewRequest",
    "fn handleTabCloseRequest",
    "fn handleSshConnectRequest",
    "fn handleSshSaveRequest",
};

const skill_center_action_markers = [_][]const u8{
    "fn scMoveSel",
    "fn skillCenterStartEnumerate",
    "fn skillCenterStartInstall",
    "fn skillCenterLibraryDir",
    "const SkillLocExec",
    "fn skillCenterTargetConn",
    "fn skillCenterLocalRootPath",
    "fn skillCenterScanOutcome",
    "const SkillTransferCtx",
    "fn skillCenterMarkerFor",
    "fn skillCenterAddMachine",
    "fn skillCenterBuildPicker",
    "fn skillCenterToolManifestPath",
    "fn skillCenterManifestJsonWithEnabled",
    "fn skillCenterOpenFileDialog",
    "fn skillCenterImportErrorSummary",
    "fn skillCenterCloneToolImportPreview",
    "fn skillCenterBinaryPlatformLabel",
    "fn skillCenterBinaryFileSize",
    "fn skillCenterToolImportConfirmText",
    "const ToolImportDraftJob",
    "fn skillCenterContinueToolImport",
    "fn skillCenterToolToggleFailed",
    "fn skillCenterToggleFirstPartyToolEnabled",
    "fn skillCenterOpenImportList",
    "fn skillCenterRunTransfer",
    "fn runTransfer",
    "fn skillCenterPreviewServerSkill",
    "fn skillCenterDeployDecide",
    "fn skillCenterImportAct",
    "const SkillLibraryScanJob",
    "fn skillCenterEntryLessThan",
    "fn skillCenterEntryFromInstalledTool",
    "fn skillCenterEntryFromFirstPartyDefinition",
    "const SkillImportScanJob",
    "const SkillDeployScanJob",
    "const SkillTransferJob",
    "fn wslSkillTransfer",
    "fn nativeSkillTransfer",
    "fn resolveRemoteSkillRoot",
    "fn nativeDeployToRemote",
    "fn nativeImportFromRemote",
    "const SkillPreviewJob",
    "const SkillInstallEnumerateJob",
    "const SkillInstallDownloadJob",
    "fn resolveDefaultBranch",
};

fn expectAbsent(marker: []const u8) !void {
    if (std.mem.indexOf(u8, appwindow_source, marker)) |offset| {
        std.debug.print("P3.1 boundary marker returned to src/AppWindow.zig: {s} at byte {d}\n", .{ marker, offset });
        return error.P3_1BoundaryRegression;
    }
}

fn expectAllAbsent(comptime markers: []const []const u8) !void {
    inline for (markers) |marker| try expectAbsent(marker);
}

test "P3.1 remote sync implementation stays out of AppWindow" {
    try expectAllAbsent(&remote_sync_markers);
}

test "P3.1 control API implementation stays out of AppWindow" {
    try expectAllAbsent(&control_api_markers);
}

test "P3.1 surface snapshot implementation stays out of AppWindow" {
    try expectAllAbsent(&surface_snapshot_markers);
}

test "P3.1 Weixin bridge implementation stays out of AppWindow" {
    try expectAllAbsent(&weixin_bridge_markers);
}

test "P3.1 agent request implementation stays out of AppWindow" {
    try expectAllAbsent(&agent_request_markers);
}

test "P3.1b Skill Center action implementations stay out of AppWindow" {
    try expectAllAbsent(&skill_center_action_markers);
}
