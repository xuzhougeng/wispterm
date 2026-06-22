# First-Party Agent Tool Disable Design

## Goal

Skill Center should inventory and manage WispTerm's first-party AI Agent tools in
the same place it already manages prompt skills and imported executable tools.
Users can turn a first-party tool off, and off means two things:

1. New AI requests do not advertise that tool in their model-facing schema.
2. If an older request or model response still tries to call that tool, runtime
   dispatch rejects it before any side effect happens.

The feature includes tools such as `webread`, `websearch`, `pubmed`,
`wispterm_docs`, terminal tools, file tools, and other built-in Agent function
tools. Imported binary tools keep their existing manifest-based enable state.

## Ghostty Comparison

Ghostty does not have an AI Agent, Skill Center, or model tool registry. Its
closest reference is `src/apprt/action.zig`, where application actions are
centrally enumerated and then routed through platform/runtime layers. WispTerm
should follow that shape for first-party Agent tools: define the built-in tool
catalog once, then let Skill Center, schema emission, and runtime dispatch all
consume that same catalog instead of duplicating tool names.

This keeps WispTerm close to Ghostty's layering principle:

- Command Center launches actions and panels.
- Skill Center manages reusable AI capabilities.
- The Agent tool registry owns model-facing tool definitions and dispatch gates.

## Product Behavior

Skill Center list rows can represent three capability kinds:

- `skill`: a prompt skill directory under the local skills library.
- `tool`: an imported executable tool under `<config>/tools/<id>/`.
- `first-party`: a built-in WispTerm Agent tool.

First-party tools are shown with `on` or `off`. They are on by default. Pressing
`E` on a first-party row toggles its state, just like imported binary tools.
Prompt skill rows remain non-toggleable.

When a tool is off:

- It stays visible in Skill Center and can be toggled back on.
- It is omitted from Chat Completions, Responses, and Anthropic tool schemas.
- Runtime dispatch returns a clear tool result such as
  `Tool is disabled: webread`.
- Subagents inherit the same disabled set, so `webread` off means it is also off
  inside the subagent's restricted research toolset.

The memory tools keep the existing `ai-memory-enabled` master switch. If memory
tools are also represented in Skill Center, the effective rule is:
`ai-memory-enabled` must be true and the individual memory tool must not be off.

## Data Model

Add a small first-party tool catalog module, for example
`src/first_party_tools.zig`.

Each tool definition should include:

- `name`: exact function tool name, e.g. `webread`.
- `label`: row label, usually the same as `name`.
- `description`: short human-facing summary for preview/status text.
- `category`: optional grouping such as terminal, file, web, docs, memory, or
  integration.
- `disableable`: true for normal tools; false only if a tool must never be
  hidden for protocol correctness.

The catalog is the source of truth for first-party tool inventory. Existing
schema text can remain in `ai_chat_protocol.zig` initially, but every emitted
first-party tool name must be present in the catalog, with tests to catch drift.

## Persistence

Persist first-party tool state under the WispTerm config directory, separate
from imported executable tool manifests. A compact file such as
`<config>/agent_tools.json` is sufficient:

```json
{
  "disabled": ["webread", "pubmed"]
}
```

Unknown names are ignored when reading so old state files remain harmless after
tools are renamed or removed. Writes should be atomic, using the existing
`platform/atomic_file.zig` helper. If the file is missing or malformed, WispTerm
falls back to all first-party tools enabled and reports toggle failures through
the Skill Center status line rather than breaking AI chat startup.

## Skill Center Integration

The Skill Center scan worker should merge entries in this order before sorting:

1. Prompt skill entries from the local skill library.
2. Imported executable tool entries from `tool_registry.scanInstalledTools`.
3. First-party tool entries from the first-party catalog plus persisted state.

Extend `skill_center.LibraryEntry` with a first-party tool variant rather than
reusing imported binary `ToolSkill`. The first-party row does not have an
executable path or manifest path, so keeping it distinct avoids fake paths and
keeps toggle code honest.

The renderer can keep the existing `ListItem.kind` and `ListItem.enabled`
columns. Use `first-party` or a short label such as `built-in` if the longer
text does not fit cleanly. The legend should say `[e] toggle` instead of only
`[e] enable`, because it applies to both on and off transitions.

All Skill Center key handlers that mutate the first-party state must keep the
existing event-driven render-loop dirtying rule: after consuming the event, set
`AppWindow.g_force_rebuild = true` and `AppWindow.g_cells_valid = false` at the
input call site.

## Schema Filtering

Add a disabled-tool lookup to `ai_chat_protocol.ToolSpecOpts`, then make
`forEachToolSpec` skip first-party tools whose names are disabled. This must
apply before protocol-specific emitters, so Chat Completions, Responses, and
Anthropic stay consistent.

Dynamic binary tools keep their current enabled filtering. A disabled
first-party name also stays reserved, so an imported binary tool cannot become
callable by taking over a disabled built-in name.

Subagent filtering composes with disabled filtering:

- First check whether the subagent toolset permits the tool.
- Then check whether the first-party disabled set hides it.

## Runtime Filtering

Extend `ai_chat_types.AgentSettings` and `ai_chat.ChatRequest` with the
first-party disabled snapshot. Request creation should clone the current
disabled set just like it already clones dynamic binary tool specs.

At the top of `ai_chat_tools.executeToolCall`, after cancellation and before any
tool-specific branch, check whether `call.name` is a first-party tool and is
disabled. If yes, return a plain tool result:

```text
Tool is disabled: <name>
```

This prevents side effects from stale tool calls and makes the model-visible
failure actionable. Imported binary tool dispatch remains controlled by
`dynamic_binary_tools`, so disabled imported tools are still absent from runtime.

`subagent` is special because it is handled in `ai_chat_request.zig` before the
leaf tool layer. The top-level `subagent` call itself should be blocked if
`subagent` is disabled. Once a subagent starts, its derived request inherits the
same disabled set.

## Testing

Add focused tests for:

- First-party catalog contains every built-in tool emitted by schema generation.
- Malformed or missing persisted state defaults to all first-party tools on.
- Skill Center mixed entries include first-party rows with `on/off`.
- Toggling a first-party row persists state and updates the in-memory row.
- Disabled `webread` is absent from Chat Completions, Responses, and Anthropic
  schemas.
- Disabled `webread` is rejected by `ai_chat_tools.executeToolCall`.
- Disabled `subagent` is rejected before `runSubagentTaskWithModel`.
- Subagent schemas inherit disabled first-party tools.
- Imported binary tool toggling still updates manifest state and does not use
  the first-party state file.

Run `zig build test` for pure model/protocol coverage. Run `zig build test-full`
before finishing because Skill Center input tests live only in the full app test
binary.

## Documentation

Update the AI Agent docs and FAQ to say Skill Center can enable/disable both
imported executable tools and first-party WispTerm Agent tools. No keyboard
shortcut README update is required unless the Skill Center key bindings change;
renaming the legend from enable to toggle is in-panel copy, not a shortcut
change.
