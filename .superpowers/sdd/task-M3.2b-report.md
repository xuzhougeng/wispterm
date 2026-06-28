# Task M3.2b Report: weixin_send_attachment → send_attachment

## 改动文件与站点

| 文件 | 改动站点 | 说明 |
|------|---------|------|
| `src/assistant/conversation/protocol.zig` | 709, 761, 774, 1539, 1551 | reserved 列表名、copy_file 描述、emitTool 名+描述、测试名、测试断言 |
| `src/tools/first_party.zig` | 52 | 注册表 name/label/description |
| `src/platform/agent_prompt.zig` | 80, 81, 185, 188 | 系统提示两行、测试名、测试断言 |
| `src/agent_tools/weixin.zig` | 顶部注释(新增), 18, 31, 38, 41, 108, 140 | ponytail 注释、错误文案、approval 标签、失败文案、成功文案、两处测试断言 |
| `src/agent_tools/mod.zig` | 209-210, 714(测试名), 730, 736, 739(测试名), 761, 774 | 分发处 + legacy alias、两个测试全量更新 |
| `src/assistant/conversation/session.zig` | 5566, 5602, 5609, 5612, 5654, 5668 | 两个测试全量更新 |
| `src/chatops/router.zig` | 559 | 测试名中立化 |

## 新文案

- 工具 ID：`send_attachment`
- emitTool 描述：`Send a local file back to the active chat conversation (WeChat or Feishu) that triggered this agent request. Use only when the current request came from a chat channel; ordinary local chat has no reply context. Audio and voice files are sent as ordinary file attachments.`
- first_party description：`Send a local file back to the active chat conversation (WeChat or Feishu).`
- 系统提示第1行：`From a chat channel (WeChat/Feishu), send generated/local artifacts with \`send_attachment\`: ...`
- 系统提示第2行：`Before sending WSL/SSH artifacts to a chat channel, call \`copy_file\` ...`
- 错误文案：`No active chat reply context; cannot send attachment.`
- 成功文案：`Sent {s} to chat: {s}`
- approval 标签：`send_attachment`
- copy_file 描述：`... useful before send_attachment. Push mode ...`

## Legacy Alias 证明

测试 `src/agent_tools/mod.zig` 中的  
`"weixin_send_attachment legacy alias still routes to sender"`  
使用旧名 `weixin_send_attachment` 调用 `executeToolCall`，断言  
`capture.called == true` 且结果为 `"Sent file to chat: report.pdf"`，  
证明 legacy alias 仍正常路由。

## 测试结果

```
zig build test                            EXIT:0   (全部通过)
zig build test-full -Dtarget=aarch64-macos 2>&1 | tail -30  EXIT:0
```

## 剩余 grep 确认

```
$ grep -rn "weixin_send_attachment" src --include="*.zig"
src/agent_tools/mod.zig:210:        std.mem.eql(u8, call.name, "weixin_send_attachment")) // legacy alias
src/agent_tools/mod.zig:741:test "weixin_send_attachment legacy alias still routes to sender" {
src/agent_tools/mod.zig:764:        .name = @constCast("weixin_send_attachment"),
```

仅剩 3 处，全为 mod.zig legacy alias 及对应测试，均为**有意保留**，无遗漏。
