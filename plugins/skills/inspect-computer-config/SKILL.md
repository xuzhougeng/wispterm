---
name: inspect-computer-config
description: Use when the user asks to inspect, summarize, audit, compare, or troubleshoot this computer's hardware, operating system, CPU, memory, GPU, disk, or local runtime configuration.
---

# Inspect Computer Config

## Overview

Collect a concise local computer configuration report without looking up external services or exposing secrets. Prefer the bundled script for repeatable OS, CPU, memory, GPU, disk, and runtime facts.

## Workflow

1. Run the bundled script from the directory that contains this `SKILL.md`:

```bash
python3 scripts/inspect_computer_config.py
```

On Windows, use `python` if `python3` is not available.

2. Use structured output when the result will feed another tool:

```bash
python3 scripts/inspect_computer_config.py --json
```

3. Include the hostname only when it is useful for local diagnostics:

```bash
python3 scripts/inspect_computer_config.py --include-hostname
```

4. Summarize the important facts for the user. Mention unavailable fields plainly instead of guessing.

## Privacy

- Do not collect public IP addresses, Wi-Fi passwords, SSH keys, license keys, environment variables, browser data, or installed application inventories.
- Do not print serial numbers or unique hardware IDs unless the user explicitly asks and understands why they are needed.
- Ask before running benchmarks, stress tests, or commands that require administrator privileges.

## Script Notes

- `scripts/inspect_computer_config.py` uses only the Python standard library.
- On Windows it calls PowerShell CIM cmdlets when available for richer CPU, memory, GPU, and disk details.
- On Linux it reads `/proc` and common command output when available.
- On macOS it uses `sysctl`, `system_profiler`, and `df` when available.
- If modifying the script, run `python3 scripts/inspect_computer_config.py --self-test` from the skill directory before using it.
