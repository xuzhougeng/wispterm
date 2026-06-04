# 设计：AI 会话技能沉淀（/distill /沉淀）

- 日期：2026-06-04
- 状态：设计已确认，待写实现计划
- 参考：Mangopi CLI 的 Goal/Skill/Memory 轻量化思路；GenericAgent 的会话经验沉淀与 Skill/SOP 机制

## 1. 背景与动机

WispTerm 已经有可用的 AI Agent、Copilot、AI History、本地 `SKILL.md` 加载、`$skill` 调用、
自定义 slash commands、Markdown export 和 Remote/Weixin AI 转发。缺口不是“再造一个 Agent”，
而是把一次成功任务里的可复用经验沉淀成之后可直接调用的技能。

目标：让用户在完成一次有价值的 AI Agent 任务后，可以把这次流程提炼成本地 `SKILL.md`。
第一版提供两个入口：

1. 自动建议：任务结束后，如果当前会话看起来包含可复用流程，提示用户是否沉淀成技能。
2. 手动命令：用户输入 `/distill [主题]` 或 `/沉淀 [主题]`，从当前会话生成候选技能。

第一版必须可控：自动建议只打开沉淀流程，不静默写文件。候选技能必须先预览，用户确认后才写入磁盘。

## 2. 现有基础设施

- `skill_registry.zig` 已支持扫描 `skills/<name>/SKILL.md`、解析 frontmatter、加载快照、检测过大文件和重复名。
- `ai_chat_skills.zig` 已合并多个 skills 根目录：平台配置目录、`plugins/skills`、当前工作目录、可执行文件旁和 macOS bundle Resources。
- AI Chat 已支持 `$skill-name` 显式加载技能，并把技能内容写成 replayable tool message，保证历史可重放。
- `command_registry.zig` 和 `ai_chat_composer.zig` 已支持本地 slash command、建议列表、命令解析和自定义命令。
- `agent_history.zig` 已保存 AI 会话记录，`ai_chat.zig` 已支持 full/clean Markdown export、rewind、resume 和 history snapshots。

结论：技能沉淀应该复用现有 `skills/` 目录和 `$skill` 机制，只新增“从会话生成候选 `SKILL.md`、预览、确认落盘、刷新索引”的闭环。

## 3. Ghostty 对照

Ghostty 没有 AI Agent、Skill 或 Remote IM 等价功能；这部分属于 WispTerm 的差异化 AI workflow 层。
可借鉴 Ghostty 的原则是命令入口一致性：Ghostty 的 `src/input/command.zig` 把 command palette
命令视为普通 binding action 的具名入口，不把命令系统做成特殊旁路。WispTerm 的 `/distill` 应同样进入
现有 AI Chat slash command 管线，而不是新建一套独立命令解释器。

终端核心、shell integration、VT 行为仍以 Ghostty 为基线；技能沉淀本身不改变终端行为。

## 4. 用户行为

### 4.1 手动命令

用户在 AI Chat、Agent tab 或 Copilot sidebar 输入：

```text
/distill
/distill ssh troubleshooting
/沉淀
/沉淀 远程 SSH 文件上传排障
```

行为：

- 没有主题时，从当前会话自动推断技能名、description 和正文。
- 有主题时，把主题作为提炼方向，仍从当前会话抽取可复用流程。
- 命令本身不发送给普通对话模型；它启动一个本地管理的 distill 请求。
- 如果当前会话内容不足，返回本地提示：`Not enough reusable context to distill yet.`

### 4.2 自动建议

每次 Agent/Copilot 请求结束后，WispTerm 判断本轮是否值得沉淀。满足任一条件可显示建议：

- 本轮或当前会话累计使用过 2 个以上工具。
- 当前会话包含失败后修正、环境探测、配置写入、脚本生成、远程/SSH/WSL 操作等可复用模式。
- 用户文本包含“以后还会用”“记住这个流程”“下次直接用”等强意图。

不显示建议的情况：

- 当前请求是 `/distill`、`/commands`、`/skills`、`/permission`、`/export`、`/resume` 等本地命令。
- 当前会话已打开一个待确认的 distill 候选。
- 当前会话本次请求没有工具调用，也没有明显可复用流程。
- 用户刚刚忽略过同一会话的建议；同一会话默认只建议一次，除非后续又发生新的工具密集任务。

建议文案：

```text
This task looks reusable. Distill it into a skill?
```

中文：

```text
这次流程看起来可复用，要沉淀成技能吗？
```

第一版可用键盘操作：选中建议后 Enter 进入预览，Esc 忽略。后续可再做鼠标按钮。

## 5. 候选技能生成

新增一个专门的 distiller prompt，而不是复用普通聊天系统 prompt。它只负责从会话材料生成一个候选 `SKILL.md`，
输出结构化 JSON，应用层再渲染为 Markdown 预览。

候选字段：

- `name`：稳定、短、ASCII slug，例如 `ssh-file-transfer-troubleshooting`。
- `description`：一句话说明何时使用该技能。
- `body`：可复用 SOP，包含适用场景、前置条件、步骤、验证、风险/禁区。
- `source_summary`：简述来自哪次会话和哪些关键证据，只显示在预览里，不写入技能正文。

生成约束：

- 不写入 API key、密码、token、主机密码、Weixin context token 等敏感信息。
- 发送给 distiller 的会话材料先经过应用层 redaction：已知 API key 字段、profile key、Weixin token/context token、
  SSH password 字段和常见 `*_TOKEN` / `*_KEY` 片段替换为 `<redacted>`。候选写入前再做一次同样扫描；命中高风险片段时阻止确认写入并提示用户重试。
- 不把一次性路径、临时文件名、机器私有绝对路径当成通用步骤，除非明确标为示例。
- 不把失败方案沉淀为建议步骤；失败只能进入“排障注意事项”。
- 不生成会破坏 WispTerm 安全规则的指令，例如要求关闭确认、绕过 access rules、隐藏 stderr。
- 正文必须是可读的 `SKILL.md`，带 frontmatter：

```markdown
---
name: ssh-file-transfer-troubleshooting
description: Diagnose and fix WispTerm SSH/SCP file transfer failures.
---

# When To Use

# Steps

# Verification

# Pitfalls
```

## 6. 预览与确认

第一版不做完整编辑器。流程如下：

1. `/distill [主题]` 或自动建议触发后，后台请求生成候选。
2. AI Chat 内显示一个本地 preview block，包含技能名、description、保存路径、正文预览和 `source_summary`。
3. 用户输入 `/distill confirm` 或 `/沉淀 确认` 才写入。
4. 用户输入 `/distill cancel` 或 `/沉淀 取消` 丢弃候选。
5. 如果目标目录已存在，确认时不覆盖，提示用户改名或删除旧技能。第一版不做自动 merge。

候选是会话内的临时状态，不写入 agent history。确认落盘后，追加一条普通本地 tool/status 消息：

```text
Distilled skill: $ssh-file-transfer-troubleshooting
Saved to: <user-config>/skills/ssh-file-transfer-troubleshooting/SKILL.md
```

确认成功后刷新当前 session 的 skill suggestions，让用户可以立刻 `$ssh-file-transfer-troubleshooting` 调用。

## 7. 写入位置与文件规则

默认写入平台配置目录下的用户 skills：

- Windows：`%APPDATA%\wispterm\skills\<slug>\SKILL.md`
- macOS：`~/Library/Application Support/wispterm/skills/<slug>/SKILL.md`
- 其他 POSIX：按 `platform_dirs.skillsDir()` 返回值

规则：

- 只写用户配置目录，不写仓库内 `plugins/skills`，避免污染发布包。
- slug 只允许 `[a-z0-9][a-z0-9-]{0,62}`；其他字符转 `-`，连续 `-` 折叠。
- `SKILL.md` 最大 256 KiB，沿用 `skill_registry.MAX_SKILL_MD_BYTES`。
- 写文件使用现有平台原子写入能力；如果需要新增 helper，应放在平台文件 facade 之后，避免在 `ai_chat.zig` 里直接拼临时文件策略。
- 不覆盖已存在技能目录；重复名返回可操作错误。

## 8. 架构

新增纯逻辑模块：

- `src/ai_skill_distill.zig`
  - slash 参数解析：`/distill`、`/沉淀`、`confirm`、`cancel`、主题文本。
  - slug 规范化。
  - 会话材料 redaction。
  - distiller prompt 构建。
  - JSON 候选解析与 `SKILL.md` 渲染。
  - 自动建议启发式。

扩展现有模块：

- `src/ai_chat_composer.zig`
  - 新增 slash command：`distill`。
  - 识别 `/distill` 和 `/沉淀`。
  - 建议列表显示 `/distill`。

- `src/ai_chat.zig`
  - Session 增加 pending distill candidate 状态。
  - 本地命令执行入口分派到 distill 流程。
  - 请求结束后调用自动建议启发式。
  - 确认后调用写入函数，并刷新 skill suggestions。

- `src/ai_chat_skills.zig`
  - 暴露用户 skill root 路径 helper，或新增专用 `defaultWritableSkillRootPath()`，避免写入只读 bundle/plugin 目录。

- 文档
  - `docs/ai-agent.md` 增加 “Skill Distillation”。
  - `README.md` AI Agent 简介可补一句技能沉淀能力，不涉及快捷键表。

## 9. 错误处理

- distiller API 失败：保留会话，显示 `Could not distill this conversation. Try again later.`
- JSON 格式无效：显示生成失败，不写文件。
- 候选缺少 name/description/body：显示生成失败。
- slug 已存在：显示冲突路径，要求换主题重试；不覆盖。
- 写入失败：显示真实 OS 错误和目标路径；不吞掉具体错误。
- 当前会话内容不足：本地提示，不调用模型。

## 10. 测试

纯模块单测：

- `/distill`、`/distill topic`、`/沉淀`、`/沉淀 主题`、confirm/cancel 参数解析。
- slug 规范化：英文、中文、空白、标点、过长、全非法字符 fallback。
- redaction：API key、password、token、Weixin context token、普通文本误伤边界。
- candidate JSON 解析：有效、缺字段、错误类型、超长正文。
- Markdown 渲染：frontmatter、正文、末尾换行、敏感字段不从 metadata 泄露。
- 自动建议启发式：工具密集建议、简单问答不建议、本地 slash command 不建议、pending candidate 不重复建议。
- 写入规则：创建目录、拒绝覆盖、路径安全。

集成/回归：

- `zig build test` 快速回归。
- 若实现触及文件创建或新增文件，按 `docs/development.md#windows-checkout-safety` 跑 Windows path-safety checks。
- 不需要 Ghostty 行为测试，因为该功能不改变终端 emulation。

## 11. 非目标

- 不自动静默写入技能。
- 不做技能自动 merge 或自动覆盖。
- 不做完整 Markdown 编辑器。
- 不把技能同步到云端或 Remote server。
- 不让 Remote/Weixin 直接写技能；Remote 用户可触发 AI Chat 命令，但桌面端仍走同一确认逻辑。
- 不改变 `plugins/skills` 发布包内容。

## 12. 后续方向

- 第二阶段加可视化 preview/editor，支持改名、编辑 description、局部修改正文。
- 从 AI History 里的历史会话沉淀技能，而不限当前打开会话。
- 增加“相似技能检测”，提示复用/扩展已有技能。
- GenericAgent 风格的自动长期记忆可作为更后续能力，但不进入第一版。
