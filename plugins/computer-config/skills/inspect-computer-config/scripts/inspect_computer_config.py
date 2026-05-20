#!/usr/bin/env python3
"""Print a concise local computer configuration report."""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def run_command(args: list[str], timeout: int = 8) -> str | None:
    if not args or shutil.which(args[0]) is None:
        return None
    try:
        completed = subprocess.run(
            args,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    output = completed.stdout.strip()
    return output or None


def bytes_to_gib(value: int | float | None) -> float | None:
    if value is None:
        return None
    return round(float(value) / (1024**3), 2)


def read_text(path: str) -> str | None:
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None


def parse_linux_meminfo(text: str | None) -> dict[str, Any]:
    if not text:
        return {}
    values: dict[str, int] = {}
    for line in text.splitlines():
        match = re.match(r"^([^:]+):\s+(\d+)\s+kB$", line)
        if match:
            values[match.group(1)] = int(match.group(2)) * 1024
    total = values.get("MemTotal")
    available = values.get("MemAvailable")
    return {
        "total_gib": bytes_to_gib(total),
        "available_gib": bytes_to_gib(available),
        "source": "/proc/meminfo",
    }


def linux_cpu_model() -> str | None:
    text = read_text("/proc/cpuinfo")
    if not text:
        return None
    for line in text.splitlines():
        if line.lower().startswith("model name"):
            return line.split(":", 1)[1].strip()
    return None


def linux_gpu_names() -> list[str]:
    output = run_command(["lspci"])
    if not output:
        return []
    names: list[str] = []
    gpu_line = re.compile(
        r"^[0-9a-fA-F:.]+\s+(?:VGA compatible controller|3D controller|Display controller):\s*(.+)$",
        re.IGNORECASE,
    )
    for line in output.splitlines():
        match = gpu_line.match(line)
        if match:
            names.append(match.group(1).strip())
    return names


def skip_disk(filesystem: str, mount: str, blocks: int) -> bool:
    fs = filesystem.lower()
    if blocks <= 0:
        return True
    if fs in {"none", "rootfs"}:
        return True
    if fs.startswith(("tmpfs", "devtmpfs", "overlay", "snapfuse")):
        return True
    if mount.startswith(("/dev", "/proc", "/run", "/snap", "/sys", "/tmp/.git", "/tmp/.agents", "/tmp/.codex")):
        return True
    if mount.startswith(("/mnt/wsl", "/usr/lib/wsl", "/usr/lib/modules/")):
        return True
    return False


def df_disks() -> list[dict[str, Any]]:
    output = run_command(["df", "-kP"])
    if not output:
        return root_disk()
    disks: list[dict[str, Any]] = []
    for line in output.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 6:
            continue
        filesystem, blocks, used, available, _capacity, mount = parts[:6]
        block_count = int(blocks)
        if skip_disk(filesystem, mount, block_count):
            continue
        disks.append(
            {
                "name": mount,
                "filesystem": filesystem,
                "total_gib": round(block_count / (1024**2), 2),
                "free_gib": round(int(available) / (1024**2), 2),
                "used_gib": round(int(used) / (1024**2), 2),
            }
        )
    return disks or root_disk()


def root_disk() -> list[dict[str, Any]]:
    usage = shutil.disk_usage(Path.cwd().anchor or "/")
    return [
        {
            "name": Path.cwd().anchor or "/",
            "filesystem": None,
            "total_gib": bytes_to_gib(usage.total),
            "free_gib": bytes_to_gib(usage.free),
            "used_gib": bytes_to_gib(usage.used),
        }
    ]


def powershell_exe() -> str | None:
    for candidate in ("pwsh", "powershell", "powershell.exe"):
        found = shutil.which(candidate)
        if found:
            return found
    return None


def powershell_json(script: str) -> dict[str, Any] | None:
    shell = powershell_exe()
    if not shell:
        return None
    output = run_command(
        [
            shell,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            script,
        ],
        timeout=15,
    )
    if not output:
        return None
    try:
        return json.loads(output)
    except json.JSONDecodeError:
        return None


def windows_details() -> dict[str, Any]:
    script = r"""
$cs = Get-CimInstance Win32_ComputerSystem
$os = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$gpu = @(Get-CimInstance Win32_VideoController | Select-Object Name, AdapterRAM, DriverVersion)
$disk = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Select-Object DeviceID, VolumeName, FileSystem, Size, FreeSpace)
[pscustomobject]@{
  manufacturer = $cs.Manufacturer
  model = $cs.Model
  os_caption = $os.Caption
  os_version = $os.Version
  memory_bytes = [int64]$cs.TotalPhysicalMemory
  cpu_name = $cpu.Name
  cpu_cores = $cpu.NumberOfCores
  cpu_logical_processors = $cpu.NumberOfLogicalProcessors
  gpu = $gpu
  disks = $disk
} | ConvertTo-Json -Depth 4 -Compress
"""
    data = powershell_json(script) or {}
    disks = []
    for item in ensure_list(data.get("disks")):
        size = safe_int(item.get("Size"))
        free = safe_int(item.get("FreeSpace"))
        disks.append(
            {
                "name": item.get("DeviceID"),
                "label": item.get("VolumeName"),
                "filesystem": item.get("FileSystem"),
                "total_gib": bytes_to_gib(size),
                "free_gib": bytes_to_gib(free),
                "used_gib": bytes_to_gib(size - free if size is not None and free is not None else None),
            }
        )
    gpus = []
    for item in ensure_list(data.get("gpu")):
        gpus.append(
            {
                "name": item.get("Name"),
                "memory_gib": bytes_to_gib(safe_int(item.get("AdapterRAM"))),
                "driver": item.get("DriverVersion"),
            }
        )
    return {
        "manufacturer": data.get("manufacturer"),
        "model": data.get("model"),
        "os_caption": data.get("os_caption"),
        "os_version": data.get("os_version"),
        "memory": {"total_gib": bytes_to_gib(safe_int(data.get("memory_bytes"))), "source": "Win32_ComputerSystem"},
        "cpu": {
            "model": data.get("cpu_name"),
            "physical_cores": safe_int(data.get("cpu_cores")),
            "logical_cores": safe_int(data.get("cpu_logical_processors")),
        },
        "gpu": gpus,
        "disks": disks,
    }


def mac_details() -> dict[str, Any]:
    cpu_model = run_command(["sysctl", "-n", "machdep.cpu.brand_string"])
    mem_bytes = safe_int(run_command(["sysctl", "-n", "hw.memsize"]))
    gpu_output = run_command(["system_profiler", "SPDisplaysDataType"], timeout=20)
    gpus: list[dict[str, Any]] = []
    if gpu_output:
        for line in gpu_output.splitlines():
            stripped = line.strip()
            if stripped.startswith("Chipset Model:"):
                gpus.append({"name": stripped.split(":", 1)[1].strip()})
    return {
        "memory": {"total_gib": bytes_to_gib(mem_bytes), "source": "sysctl hw.memsize"},
        "cpu": {"model": cpu_model, "logical_cores": os.cpu_count()},
        "gpu": gpus,
        "disks": df_disks(),
    }


def linux_details() -> dict[str, Any]:
    os_release = parse_os_release(read_text("/etc/os-release"))
    return {
        "os_caption": os_release.get("PRETTY_NAME"),
        "memory": parse_linux_meminfo(read_text("/proc/meminfo")),
        "cpu": {"model": linux_cpu_model() or platform.processor() or None, "logical_cores": os.cpu_count()},
        "gpu": [{"name": name} for name in linux_gpu_names()],
        "disks": df_disks(),
    }


def parse_os_release(text: str | None) -> dict[str, str]:
    data: dict[str, str] = {}
    if not text:
        return data
    for line in text.splitlines():
        if "=" not in line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        data[key] = value.strip().strip('"')
    return data


def ensure_list(value: Any) -> list[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def safe_int(value: Any) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def base_report(include_hostname: bool) -> dict[str, Any]:
    system = platform.system()
    report: dict[str, Any] = {
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "system": {
            "platform": system,
            "release": platform.release(),
            "version": platform.version(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
    }
    if include_hostname:
        report["system"]["hostname"] = socket.gethostname()
    if system == "Windows":
        details = windows_details()
    elif system == "Darwin":
        details = mac_details()
    elif system == "Linux":
        details = linux_details()
    else:
        details = {
            "memory": {},
            "cpu": {"model": platform.processor() or None, "logical_cores": os.cpu_count()},
            "gpu": [],
            "disks": root_disk(),
        }
    report.update(details)
    return report


def format_value(value: Any) -> str:
    if value is None or value == "":
        return "unavailable"
    return str(value)


def format_markdown(report: dict[str, Any]) -> str:
    system = report.get("system", {})
    cpu = report.get("cpu", {})
    memory = report.get("memory", {})
    lines = [
        "# Computer Configuration",
        "",
        f"- Generated: {format_value(report.get('generated_at'))}",
        f"- OS: {format_value(report.get('os_caption') or system.get('platform'))} {format_value(report.get('os_version') or system.get('release'))}",
        f"- Architecture: {format_value(system.get('machine'))}",
        f"- Python: {format_value(system.get('python'))}",
    ]
    if "hostname" in system:
        lines.append(f"- Hostname: {format_value(system.get('hostname'))}")
    if report.get("manufacturer") or report.get("model"):
        lines.append(f"- Computer: {format_value(report.get('manufacturer'))} {format_value(report.get('model'))}".strip())
    lines.extend(
        [
            "",
            "## CPU",
            f"- Model: {format_value(cpu.get('model'))}",
            f"- Physical cores: {format_value(cpu.get('physical_cores'))}",
            f"- Logical cores: {format_value(cpu.get('logical_cores'))}",
            "",
            "## Memory",
            f"- Total: {format_value(memory.get('total_gib'))} GiB",
        ]
    )
    if memory.get("available_gib") is not None:
        lines.append(f"- Available: {format_value(memory.get('available_gib'))} GiB")
    lines.extend(["", "## GPU"])
    gpus = report.get("gpu") or []
    if gpus:
        for gpu in gpus:
            details = [format_value(gpu.get("name"))]
            if gpu.get("memory_gib") is not None:
                details.append(f"{gpu['memory_gib']} GiB")
            if gpu.get("driver"):
                details.append(f"driver {gpu['driver']}")
            lines.append(f"- {'; '.join(details)}")
    else:
        lines.append("- unavailable")
    lines.extend(["", "## Disks"])
    for disk in report.get("disks") or []:
        name = format_value(disk.get("name"))
        total = format_value(disk.get("total_gib"))
        free = format_value(disk.get("free_gib"))
        fs = disk.get("filesystem")
        suffix = f" ({fs})" if fs else ""
        lines.append(f"- {name}{suffix}: {total} GiB total, {free} GiB free")
    return "\n".join(lines)


def self_test() -> None:
    assert bytes_to_gib(1024**3) == 1.0
    mem = parse_linux_meminfo("MemTotal:       2097152 kB\nMemAvailable:    524288 kB\n")
    assert mem["total_gib"] == 2.0
    assert mem["available_gib"] == 0.5
    os_release = parse_os_release('NAME="Example OS"\nPRETTY_NAME="Example OS 1"\n')
    assert os_release["PRETTY_NAME"] == "Example OS 1"
    original_run_command = run_command
    try:
        def fake_df(args: list[str], timeout: int = 8) -> str | None:
            if args == ["df", "-kP"]:
                return "\n".join(
                    [
                        "Filesystem 1024-blocks Used Available Capacity Mounted on",
                        "/dev/sdd 1055762868 593698532 408360864 60% /",
                        "rootfs 12299436 2720 12296716 1% /init",
                        "none 12304476 0 12304476 0% /run",
                        "snapfuse 75776 75776 0 100% /snap/core22/2339",
                        "C:\\ 1952482508 780640464 1171842044 40% /mnt/c",
                    ]
                )
            return None

        globals()["run_command"] = fake_df
        assert [disk["name"] for disk in df_disks()] == ["/", "/mnt/c"]

        def fake_lspci(args: list[str], timeout: int = 8) -> str | None:
            if args == ["lspci"]:
                return "bd91:00:00.0 3D controller: Microsoft Corporation Device 008e"
            return None

        globals()["run_command"] = fake_lspci
        assert linux_gpu_names() == ["Microsoft Corporation Device 008e"]
    finally:
        globals()["run_command"] = original_run_command
    text = format_markdown(
        {
            "generated_at": "2026-01-01T00:00:00+00:00",
            "system": {"platform": "TestOS", "release": "1", "machine": "x86_64", "python": "3"},
            "cpu": {"model": "CPU", "logical_cores": 8},
            "memory": {"total_gib": 16},
            "gpu": [{"name": "GPU"}],
            "disks": [{"name": "/", "total_gib": 100, "free_gib": 50}],
        }
    )
    assert "# Computer Configuration" in text
    assert "CPU" in text


def main() -> int:
    parser = argparse.ArgumentParser(description="Inspect local computer configuration.")
    parser.add_argument("--json", action="store_true", help="print machine-readable JSON")
    parser.add_argument("--include-hostname", action="store_true", help="include the local hostname in the report")
    parser.add_argument("--self-test", action="store_true", help="run lightweight parser and formatter tests")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        print("self-test passed")
        return 0

    report = base_report(include_hostname=args.include_hostname)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(format_markdown(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
