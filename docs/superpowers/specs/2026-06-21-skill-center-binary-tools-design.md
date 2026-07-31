# Skill Center Binary Tools Design

## Goal

Extend Skill Center so it manages two kinds of AI capabilities:

1. **Prompt skills**: existing `SKILL.md` directories.
2. **Executable tool skills**: imported local binary tools that the AI Agent can call as function tools.

The first version keeps the user-facing model simple: tools are skills. Skill Center remains the single place to inventory, import, preview, enable, and disable reusable AI capabilities.

## Ghostty Comparison

Ghostty's command palette is action-centric: commands are discoverable entries tied to normal application actions and bindings. It does not manage external executables or plugin lifecycles. WispTerm should keep the same separation of responsibilities:

- Command Center remains the launcher for app actions, including opening Skill Center.
- Skill Center owns reusable AI capabilities and their lifecycle.
- The AI tool registry owns model-facing tool schemas and runtime dispatch.

This matches Ghostty's command-palette layering while extending WispTerm's AI-specific surface where Ghostty has no equivalent feature.

## Product Decisions

- No separate Tool Center in the first version.
- Skill Center rows can represent either prompt skills or executable tool skills.
- Executable tools are local desktop tools in the first version. Remote deployment/import for binaries is out of scope.
- Enabled tools are advertised to AI Agent requests as callable function tools.
- Disabled tools remain installed and previewable but are not sent to the model.
- A tool import is valid when one of these is true:
  - The binary supports both `--help` and `--skill`.
  - The binary is imported with a sibling or packaged `SKILL.md`.
  - WispTerm generates a draft `SKILL.md` during import, using `--help` when available and AI-assisted analysis when it is not.
- If a binary has no usable `--skill`, no `SKILL.md`, and no usable `--help`, import can still proceed through AI-assisted `SKILL.md` generation. The generated draft must be previewed and accepted by the user before the tool can be enabled.

## Tool Package Shape

Imported tools live under the WispTerm config directory:

```text
<config>/tools/<tool-id>/
  manifest.json
  SKILL.md
  bin/<original-binary-name>
```

`manifest.json` stores only local metadata:

```json
{
  "kind": "binary_tool",
  "id": "agent_docx_review",
  "function_name": "agent_docx_review",
  "enabled": true,
  "executable": "bin/agent_docx_review.exe",
  "source_path": "C:\\Users\\alice\\Downloads\\agent_docx_review.exe",
  "sha256": "...",
  "imported_at_ms": 1781971200000,
  "description": "Apply tracked-change review scripts to DOCX files"
}
```

The stored `SKILL.md` is the canonical model-facing and human-preview description for the tool. It may come from `binary --skill`, from an imported file, or from WispTerm's generated draft.

## Import Flow

The first version supports importing one binary file at a time.

1. User opens Skill Center and chooses **Import Tool**.
2. WispTerm asks for a binary file with the platform file picker.
3. WispTerm copies the binary into a staging directory.
4. WispTerm runs metadata probes with a short timeout and output cap:
   - `<binary> --help`
   - `<binary> --skill`
5. WispTerm resolves `SKILL.md` content:
   - Prefer successful non-empty `--skill` output.
   - Otherwise use sibling `SKILL.md` next to the selected binary.
   - Otherwise generate a deterministic draft `SKILL.md` from successful `--help` output.
   - Otherwise ask the configured AI profile to draft `SKILL.md` from available evidence.
6. WispTerm shows a preview/editor overlay with the resolved or generated `SKILL.md`.
7. User confirms import. WispTerm atomically moves the staged package into `<config>/tools/<tool-id>/`.

The deterministic draft uses the binary basename, the first useful line of `--help`, the full help text, and a short invocation note explaining that the AI passes command-line arguments through the tool's `args` array.

The AI-assisted draft path is used only when no usable `--skill`, no sibling `SKILL.md`, and no usable `--help` output exists. It uses evidence WispTerm can gather safely: binary basename, file size, hash, optional `version`/`--version` output, platform, and any user-entered note in the import overlay. The prompt must instruct the model not to invent unsupported commands and to produce a cautious `SKILL.md` that names uncertainty. The user must review the generated draft before import completes. If no AI profile is configured, WispTerm should ask the user to provide a `SKILL.md` or configure a model profile before continuing.

## Generated `SKILL.md`

Generated content uses this shape:

````markdown
---
name: agent_docx_review
description: Apply tracked-change review scripts to DOCX files
---

# agent_docx_review

Use this executable tool when the task matches the help text below.

## Invocation

Call the `agent_docx_review` tool with an `args` array containing the command-line arguments that should follow the executable name. Do not include the executable name itself.

## Help

```text
<captured --help output>
```
````

If the binary also supports `--json` or subcommand-specific help, that remains part of the author's tool documentation; the first version does not infer a richer JSON schema from it.

When the draft is AI-assisted with no help text, the generated `SKILL.md` should use a stricter template:

```markdown
---
name: tool_name
description: Local executable tool imported into WispTerm
---

# tool_name

This tool was imported from a binary without `--skill`, `--help`, or a packaged `SKILL.md`. The description below is an AI-generated draft from limited metadata and must be corrected by the user before relying on it.

## Invocation

Call the `tool_name` tool with an `args` array containing the command-line arguments that should follow the executable name. Do not include the executable name itself.

## Known Evidence

- filename: ...
- platform: ...
- version output: ...

## Usage Notes

...
```

This makes the uncertainty visible to both the user and the model.

## AI Tool Schema

Each enabled binary tool becomes one function tool. The default function name is the sanitized binary basename, for example `agent_docx_review`. Names must be valid model tool names and must not collide with built-in WispTerm tools or another enabled binary tool. On collision, import requires the user to rename the tool id/function name before enabling it.

First-version schema is generic and stable:

```json
{
  "args": {
    "type": "array",
    "items": { "type": "string" },
    "description": "Command-line arguments to pass after the executable name."
  },
  "cwd": {
    "type": "string",
    "description": "Optional working directory. Defaults to the AI Agent working directory."
  },
  "timeout_ms": {
    "type": "integer",
    "description": "Optional timeout. Defaults to ai-agent-command-timeout-ms."
  }
}
```

The tool description sent to the model is derived from the stored `SKILL.md`, truncated to a safe limit. The full text remains available in Skill Center preview.

This generic argv design avoids guessing command semantics from help text. A later version can allow a tool to publish a structured schema, but the first version should prioritize a reliable import/call path.

## Runtime Dispatch

`ai_chat_protocol.zig` currently emits built-in tool schemas from one static function. The design adds a dynamic tool list to the request-building path so enabled binary tools can be appended after built-ins for chat completions, Responses, and Anthropic protocols.

`ai_chat_tools.zig` resolves unknown tool calls against the same enabled-tool snapshot. When a binary tool is called:

1. Parse `args`, `cwd`, and `timeout_ms`.
2. Build argv as `[executable_path] + args`.
3. Spawn the binary directly with `std.process.Child`; never through a shell.
4. Capture stdout/stderr with the existing output limit and timeout behavior.
5. Return:

```text
exit_code=0
stdout:
...
stderr:
...
```

The executable path always points inside `<config>/tools/<tool-id>/bin/`. The model never supplies the executable path.

## Permissions

Enabling a tool controls whether the model can see it. It is not a permission bypass.

Binary tools are arbitrary local executables, so first-version calls are treated as high-risk local execution:

- `ai-agent-permission = ask`: always ask before running.
- `ai-agent-permission = auto`: still ask before running binary tools.
- `ai-agent-permission = full`: run without asking.

The approval prompt shows the tool name, effective cwd, and argv. This is stricter than `shell_exec`, but appropriate until tool manifests can declare safer read-only behavior.

## Skill Center UI

Skill Center gains a local tools inventory alongside the existing skills library.

Rows display:

- name
- kind: `skill` or `tool`
- enabled state for tools
- short description

Actions:

- `Space`: preview `SKILL.md` for either kind.
- `T`: import a binary tool.
- `E`: enable/disable the selected tool.
- `R`: rescan skills and tools.
- Existing deploy/import actions continue to apply only to prompt skills in the first version.

Because this changes visible Skill Center key text, update the Skill Center legend strings in `src/i18n.zig` and the relevant input handling in `src/input.zig`. Since Skill Center is an event-driven non-terminal panel, every consumed key that mutates selection, overlay state, filter text, or enabled state must set:

```zig
AppWindow.g_force_rebuild = true;
AppWindow.g_cells_valid = false;
```

## Modules

### `src/tool_registry.zig`

Pure-ish registry module for executable tools:

- parse/write `manifest.json`
- sanitize tool ids/function names
- load enabled tools
- validate collisions with built-ins and other tools
- format generated `SKILL.md`
- scan `<config>/tools`

### `src/tool_import.zig`

Impure import/probe helpers:

- run `--help` and `--skill` with timeout and output caps
- locate sibling `SKILL.md`
- copy the binary into staging
- hash the binary
- atomically install the staged package

### `src/skill_center.zig`

Extend the panel model:

- library entries become a tagged union or parallel lists for prompt skills and tools
- tool rows carry enabled state and manifest metadata
- overlays add import preview and enable/disable confirmation if needed

### `src/renderer/skill_center_renderer.zig`

Keep the existing Skill Center visual style. Add row metadata rendering for kind/enabled state without introducing a separate page.

### `src/ai_chat_protocol.zig`

Append enabled dynamic tool schemas after built-ins in every protocol emitter.

### `src/ai_chat_tools.zig`

Dispatch dynamic binary tool calls by direct argv execution.

## Error Handling

Import errors:

- binary cannot be read or copied
- binary is not executable on the current platform
- no documentation source exists and AI-assisted generation cannot run
- generated or supplied `SKILL.md` is empty or too large
- function name collides with an existing tool

Runtime errors:

- tool disabled between request build and execution
- executable missing from installed package
- invalid `args` JSON
- spawn failure
- timeout
- non-zero exit code

Runtime errors return tool-result text rather than throwing out of the AI request, matching the existing tool layer.

## Tests

Fast/unit tests:

- tool id sanitization and collision detection
- manifest parse/write round trip
- generated `SKILL.md` from captured `--help`
- import decision matrix:
  - `--help` + `--skill`
  - `--help` + sibling `SKILL.md`
  - `--help` only -> generated `SKILL.md`
  - no usable docs + configured AI profile -> AI-assisted draft requiring user approval
  - no usable docs + no AI profile -> blocked with clear next step
- dynamic schema JSON includes enabled tools and excludes disabled tools
- dispatch builds argv without shell interpolation

Full app tests:

- Command Center still opens Skill Center.
- Skill Center input handlers dirty the UI on tool import/enable/disable/preview navigation.
- AI request schema includes an enabled imported tool.
- Calling a fake imported tool returns captured stdout/stderr.

Before finishing implementation, run `zig build test` and `zig build test-full`. If files are added, removed, renamed, or moved, also run the Windows checkout-safety checks from `docs/development.md`.

## Scope Guards

- Local executable tools only.
- One generic argv schema per tool.
- No remote binary deploy/import.
- No marketplace or URL download for tools.
- No shell execution path for binary tools.
- AI-assisted `SKILL.md` generation is allowed only as the fallback when no tool-authored documentation exists, and the draft must be user-reviewed before enabling.
- No structured schema inference from `--help`.
- No per-tool read-only trust policy in the first version.
