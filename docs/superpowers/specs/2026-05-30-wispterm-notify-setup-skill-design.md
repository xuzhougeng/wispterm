# 设计：WispTerm 通知配置技能（`wispterm-notify-setup`）

> 状态：已通过 brainstorming 评审,待写实现计划。
> 日期：2026-05-30
> 关联:把本会话手动搭好的"WispTerm 提醒"打包成可复用安装器。富通知(OSC)的呈现端由 **PR #101**(`feat/wispterm-osc-notifications`,Feature #1)负责;本技能是**发送端 + 安装器**,与 #101 解耦(BEL 路径不依赖 #101)。

## 1. 背景与动机

本会话此前手动为这台机器搭了"提醒":写了 `~/.claude/hooks/wispterm-notify.sh`(沿 `/proc` 找 `claude` 的 pts、写 BEL → WispTerm 铃铛指示器),并在 `~/.claude/settings.json` 接了 `Stop` + `Notification` 两个钩子。

目标:把这套**打包成 `plugins/skills/` 下的一个技能**,跑一次就能在任意 Unix 目标机上幂等装好 —— 并按评审结论扩展为:跨 Linux/WSL + macOS、发 OSC 777 富通知 + BEL 兜底、同时配置 Claude Code 与 Codex。

## 2. 关键发现(已存在、可复用)

- 本仓 `plugins/skills/<name>/` 既有范式:`SKILL.md` + `agents/openai.yaml`(Codex 接口)+ `scripts/`(`inspect-computer-config`、`wispterm-diagnostics` 即此结构)。
- Codex 已安装并在用(`~/.codex/skills/sealos-remote-deploy/`);`~/.codex/config.toml` 存在但**无 `notify` 键**。
- hook 无受控终端(`/dev/tty` = ENXIO):必须沿父进程链找到 agent 进程绑定的 tty 再写。Linux 用 `/proc`;macOS 无 `/proc`,需用 `ps`。
- WispTerm(ghostty 内核)把 OSC 9 / OSC 777 解析成同一个 `show_desktop_notification`(带 title/body);PR #101 让它在 macOS 弹原生 toast、其它平台落铃铛 badge。

## 3. 已确认的设计决策

1. **平台:Unix(Linux/WSL + macOS)**;一份 sh notify 脚本按 OS 分支做 tty 发现;Windows 暂不做。
2. **发送格式:OSC 777(富 title+body)+ BEL,两者都发**;不发 OSC 9(避免支持两者的终端双弹)。BEL 是老/未更新终端的通用兜底。
3. **同时配置 Claude Code 与 Codex**;一份 **agent 无关**的 notify 脚本(CC 走 **stdin**、Codex 走 **argv**)。
4. **位置**:`plugins/skills/wispterm-notify-setup/`,本仓新分支 → 新 PR。
5. **notify 程序装到共享中立路径** `~/.config/wispterm/wispterm-notify.sh`(CC 与 Codex 都引用它)。
6. **幂等、先备份、只增不毁**;Codex 已有别的 `notify` 时只告警不覆盖。

## 4. 架构(方案 A1:bundled 安装脚本 + 薄 SKILL.md)

否决 A2(纯 SKILL.md 让 agent 手改 JSON/TOML:非确定、幂等难保)、A3(只给片段手贴:不自动化)。

```
plugins/skills/wispterm-notify-setup/
├── SKILL.md                        # name/description + Workflow(跑安装器→汇报→验证)
├── agents/openai.yaml              # Codex 接口
└── scripts/
    ├── wispterm-notify.sh          # ★ notify 程序(装到目标机、被 CC/Codex 调用)
    ├── install-wispterm-notify.sh  # 幂等安装器(装程序 + 接线 CC + Codex)
    └── test-install.sh             # 纯 sh 测试(临时 HOME + WISPTERM_NOTIFY_TTY)
```

### 4.1 `wispterm-notify.sh`(运行期、agent 无关)

- **取 payload**:有非空 `argv[1]` → Codex(事件 JSON 在 argv);否则读 stdin → Claude Code;都没有 → 退 0。
- **解析 title/body**(有 `jq` 用之,无则降级):

  | payload 特征 | title | body |
  |---|---|---|
  | CC `.hook_event_name=="Stop"` | `Claude Code` | `完成,轮到你了` |
  | CC `.hook_event_name=="Notification"` | `.title // "Claude Code"` | `.message // .notification_type` |
  | Codex(有 `.type`) | `Codex` | `.["last-assistant-message"]`(截断~120)`// .type // "Turn complete"` |
  | 无 jq / 解析失败 | `Claude Code` | `Notification` |

- **tty 发现**(沿父链找 agent 的 tty):
  - Linux/WSL(`uname -s`=Linux):走 `/proc/$pid/status` PPid,看 `/proc/$pid/fd/{1,0,2}` → `/dev/pts/*`。
  - macOS(Darwin):`ps -o tty= -p $pid` 取 tty,为 `??` 则 `ps -o ppid= -p $pid` 上溯;命中 `ttysNNN` → `/dev/ttysNNN`。
  - 找不到 → 退 0。
- **测试接缝**:若设了环境变量 `WISPTERM_NOTIFY_TTY`,直接写它、跳过发现(供自动化测试)。
- **emit**:向目标 tty 写 `printf '\033]777;notify;%s;%s\007' "$title" "$body"` **再** `printf '\a'`。
- **净化/截断**:title/body 先删控制字符(`\033 \007 \r \n`)、`;` 替换(777 分隔符)、title≤256 / body≤1024。
- **无脚本侧限流/去重**(WispTerm 侧已做);**始终 exit 0**、排空 stdin、不阻塞。

### 4.2 `install-wispterm-notify.sh`(安装期、POSIX sh、Linux/WSL+macOS)

幂等三步,每步先备份、只增不毁:

1. **装程序**:复制 `wispterm-notify.sh` → `~/.config/wispterm/wispterm-notify.sh`(建目录、`chmod +x`、绝对路径)。
2. **接线 CC**(`~/.claude/settings.json`):不存在→建 `{}`;备份 `.bak`;用内嵌 **python3 `json`** 确保 `.hooks.Stop` 和 `.hooks.Notification` 各含一条 `command` = 安装路径的钩子(已存在跳过、缺则追加、不动其它钩子)。无 python3 → 用 `jq`;都无 → 打印精确 JSON 片段让用户手贴。
3. **接线 Codex**(`~/.codex/config.toml`):不存在→建空;备份 `.bak`;顶层单个 `notify = ["<abs-path>"]` —— 无则追加、已是我们的则跳过、**已指向别处则告警不覆盖**。用谨慎文本检查/追加(只认顶层 `notify =` 行),不做全量 TOML 重写。
   > **实现期前置校验(未在本会话核实)**:Codex `notify` 的确切调用约定 —— 它如何把事件 JSON 交给程序(argv 末参 vs 其它)、触发哪些事件类型(如 `agent-turn-complete`)、`~` 是否展开。须对照当前 Codex 版本文档/实测确认后再定稿 `wispterm-notify.sh` 的 argv 解析与 config.toml 写法;若约定与此处假设不符,以实测为准并回标本 spec。
4. **汇报 + 验证**:打印改了什么;末尾给验证命令 `echo '{"hook_event_name":"Notification","title":"WispTerm","message":"setup ok"}' | ~/.config/wispterm/wispterm-notify.sh`。

依赖与降级:python3(首选)→ jq → 手贴片段;均带 `.bak`。

### 4.3 `SKILL.md` + `agents/openai.yaml`

- `SKILL.md` frontmatter:`name: wispterm-notify-setup`;`description: Use when the user wants to install/repair WispTerm notification reminders (Stop + Notification) for Claude Code and Codex on this Unix machine, so finishes and confirmation prompts surface inside WispTerm.` 正文:Overview + Workflow(跑安装器 → 转述改动 → 跑验证命令请用户确认 → 注意事项:仅 Unix、需在 WispTerm 内运行、Codex 已有 notify 时只告警)。
- `agents/openai.yaml`:
  ```yaml
  interface:
    display_name: "WispTerm Notify Setup"
    short_description: "Install WispTerm notify hooks for Claude Code + Codex"
    default_prompt: "Use $wispterm-notify-setup to install WispTerm Stop/Notification reminders on this machine."
  ```

## 5. 测试

- **① 安装器幂等 + 合并(最高风险,临时 HOME)**:预置含 `PreToolUse`(rtk)的 `settings.json` → 跑后断言 Stop+Notification 已加、PreToolUse 保留、JSON 合法;再跑 → 无重复。`config.toml`:无 notify → 加;预置指向别处 → 未覆盖 + 告警;再跑 → 幂等。
- **② notify emit/解析(`WISPTERM_NOTIFY_TTY` 指向临时文件)**:喂 CC-stdin 与 Codex-argv 两种 payload,断言文件含正确 OSC 777 + BEL、title/body 映射对。
- **③ 净化/截断**:喂含 `;`、`\033`、换行、超长内容,断言被剥离/截断、OSC 不被破坏。
- 载体:`scripts/test-install.sh`(纯 sh),手动/CI 可跑;**不**接入 `zig build test`。
- **手验**:真实跑安装器 + 验证命令,在 WispTerm 确认铃铛/toast。

## 6. 范围边界(YAGNI / 本期不做)

- **Windows / PowerShell** notify 路径 —— 暂不做(评审选 A=Unix)。
- **卸载/禁用** 子命令 —— 本期只做"配置/幂等重配";移除留待后续。
- **脚本侧限流/去重** —— 交给 WispTerm 侧(Feature #1)。
- **OSC 9 发送** —— 只发 OSC 777 + BEL。
- 不依赖 PR #101 合并:BEL 路径今天即可用;OSC 富通知在 WispTerm 装了 #101 后自动生效。

## 7. 影响文件一览

- 新增 `plugins/skills/wispterm-notify-setup/SKILL.md`
- 新增 `plugins/skills/wispterm-notify-setup/agents/openai.yaml`
- 新增 `plugins/skills/wispterm-notify-setup/scripts/wispterm-notify.sh`
- 新增 `plugins/skills/wispterm-notify-setup/scripts/install-wispterm-notify.sh`
- 新增 `plugins/skills/wispterm-notify-setup/scripts/test-install.sh`
