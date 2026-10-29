# Magpie model connection

Requires a WispTerm build with `src/assistant/profile/magpie.zig`. Older released
builds do not read this file. The Agent plugin lives in the separate
[magpie-agents repository](https://github.com/xuzhougeng/magpie-agents).

## Connect

Configure your model provider in Magpie, then install the local Agent package:

```sh
magpie plugin add /absolute/path/to/magpie-agents/packages/agent-wispterm
magpie wispterm magpie/provider/model
```

Replace `provider/model` with a model available in Magpie and keep its gateway
running. Once published, the package can also be installed with
`magpie plugin add @hoptoper/magpie-agent-wispterm@alpha`.

Restart WispTerm after connecting, changing models, or disconnecting. A read-only
**Magpie** profile becomes the default for new Agent/Copilot sessions. Existing
personal profiles remain selectable; a personal profile already named Magpie
keeps its name and the managed one receives a suffix. Existing sessions keep
their profile snapshot until recreated. Manage the external model in Magpie.

To disconnect, run `magpie wispterm default` once, then restart WispTerm.

## Configuration and preservation

The fixed path is `~/.config/wispterm/magpie.json`, including on macOS. Windows
uses `%USERPROFILE%\.config\wispterm\magpie.json`. This path is independent of
WispTerm's native configuration directory and `XDG_CONFIG_HOME`.

Magpie writes `baseURL`, `apiKey`, and `model`; WispTerm reads all three as a unit.
Missing, partial, invalid, oversized files, and `{}` are treated as inactive.
The integration uses OpenAI Chat Completions; model IDs are passed unchanged.
Vision is off for this managed profile because the file does not declare model
capabilities.

The managed profile is never saved into `ai_profiles`, and connecting does not
rewrite the saved `ai-default-profile` preference. There is an extra profile slot
so all 16 personal profiles remain available. Magpie restores the external file's
previous values on disconnect. If no valid file existed before connection,
WispTerm resumes its personal default. An earlier valid external configuration
becomes active again when restored.

Magpie v0.1.1986 has a known issue with two consecutive `default` commands: the
second can delete a restored model field. Disconnect once per connection. See
the plugin repository's verification report for the reproduction.

## Verification

`zig build test-full -Dtarget=aarch64-macos` covers parsing, model switching,
personal-profile preservation, and existing application tests. The optional
`src/test_magpie_gateway.zig` executable uses the real protocol URL builder and
platform HTTP client against a temporary gateway. Build/run instructions live
in `magpie-agents/docs/verification.md`; it requires `MAGPIE_TEST_CONFIG` and never
loads personal settings.
