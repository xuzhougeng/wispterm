"""Publish desktop assets with one release body and a complete-asset gate."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def download_rows(tag):
    if not re.fullmatch(r"v\d+\.\d+\.\d+|\d+\.\d+(?:\.\d+)?", tag):
        raise ValueError(f"Invalid release tag: {tag}")
    return [
        ("Windows（默认 D3D11）", f"wispterm-windows-portable-{tag}.zip"),
        ("Windows（兼容包，含 WebView2/ConPTY）", f"wispterm-windows-portable-compat-{tag}.zip"),
        ("Windows（OpenGL 回退）", f"wispterm-windows-portable-opengl-{tag}.zip"),
        ("Windows（诊断构建）", f"wispterm-windows-debug-{tag}.zip"),
        ("macOS Apple Silicon", f"wispterm-macos-aarch64-{tag}.dmg"),
        ("macOS Intel", f"wispterm-macos-x86_64-{tag}.dmg"),
        ("Linux x86_64（实验性）", f"WispTerm-{tag.removeprefix('v')}-x86_64.AppImage"),
        ("wisptermctl（所有桌面平台）", f"wisptermctl-{tag}.zip"),
        ("Windows CPU performance baseline / 性能基线", f"benchmark-windows-{tag}.md"),
    ]


def required_assets(tag):
    return {name for _, name in download_rows(tag)} | {f"benchmark-windows-{tag}.json"}


def render_notes(tag, repo, curated):
    rows = download_rows(tag)
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repo):
        raise ValueError(f"Invalid repository: {repo}")
    if not curated.strip():
        raise ValueError("Release notes must not be empty")
    base = f"https://github.com/{repo}/releases/download/{tag}/"
    body = curated.rstrip() + "\n\n---\n\n"
    # Preserve an author's existing baseline section (e.g. v1.37.0); future
    # curated notes only need to describe the actual changes.
    if not re.search(r"^## (?:Performance baseline|性能基线)\b", curated, re.MULTILINE):
        body += (
            "## Performance baseline / 性能基线\n\n"
            "Windows x86_64, ReleaseFast: "
            "`wispterm-bench --case terminal-stream --duration 1000`. "
            "This measures CPU terminal-parser throughput, not GPU rendering or input latency. "
            "GitHub-hosted runner hardware can vary; compare results on equivalent hardware.\n\n"
            "每次发布自动测量并附上报告；该基线衡量终端解析吞吐量，不代表 GPU 渲染或输入延迟。"
            "GitHub 托管 runner 的硬件可能变化，请在相同硬件条件下比较结果。\n\n"
        )
    body += (
        f"[Benchmark Markdown / 基准报告]({base}benchmark-windows-{tag}.md) · "
        f"[JSON]({base}benchmark-windows-{tag}.json)\n\n"
        "## Downloads / 下载\n\n"
        "| Platform / 平台 | Package / 下载包 |\n| --- | --- |\n"
    )
    body += "".join(f"| {label} | [{name}]({base}{name}) |\n" for label, name in rows)
    return body


def missing_assets(tag, assets):
    uploaded = {a["name"] for a in assets if a["state"] == "uploaded" and a["size"] > 0}
    return required_assets(tag) - uploaded


def gh(*args, check=True):
    return subprocess.run(["gh", *args], text=True, encoding="utf-8", capture_output=True, check=check)


def release_info(tag, repo):
    result = gh("release", "view", tag, "--repo", repo, "--json", "databaseId,isDraft,assets", check=False)
    return json.loads(result.stdout) if result.returncode == 0 else None


def publish(tag, repo, assets, body):
    expected = required_assets(tag)
    names = {asset.name for asset in assets}
    for asset in assets:
        if asset.name not in expected or not asset.is_file() or asset.stat().st_size == 0:
            raise ValueError(f"Missing, empty, or unexpected release asset: {asset}")
    if any(name.startswith("wispterm-windows-") for name in names):
        if not {f"benchmark-windows-{tag}.md", f"benchmark-windows-{tag}.json"} <= names:
            raise ValueError("Windows publication requires both benchmark reports")

    with tempfile.TemporaryDirectory(prefix="wispterm-release-") as directory:
        notes = Path(directory) / "notes.md"
        notes.write_text(body, encoding="utf-8")
        if release_info(tag, repo) is None:
            created = gh("release", "create", tag, "--repo", repo, "--verify-tag", "--draft",
                         "--title", tag, "--notes-file", str(notes), check=False)
            # Another platform can create the same draft between view/create.
            if created.returncode and release_info(tag, repo) is None:
                raise RuntimeError(created.stderr)

        if assets:
            gh("release", "upload", tag, *(str(asset) for asset in assets), "--repo", repo, "--clobber")
        # Every platform writes the same body, so concurrent completions and
        # retries cannot drop the download table or another platform's notes.
        gh("release", "edit", tag, "--repo", repo, "--notes-file", str(notes))
        release = release_info(tag, repo)
        if release is None:
            raise RuntimeError("Could not read release after uploading assets")
        missing = missing_assets(tag, release["assets"])
        if missing:
            if not release["isDraft"]:
                raise ValueError(f"Published release is missing assets: {', '.join(sorted(missing))}")
            print(f"Draft {tag}: waiting for {', '.join(sorted(missing))}")
        elif release["isDraft"]:
            # GitHub's legacy policy uses semantic version/date ordering, so
            # finishing an older build later does not forcibly set it latest.
            gh("api", f"repos/{repo}/releases/{release['databaseId']}", "--method", "PATCH",
               "-F", "draft=false", "-f", "make_latest=legacy", "--silent")
            print(f"Published {tag}: all {len(expected)} assets are uploaded")
        else:
            print(f"Updated {tag}: all {len(expected)} assets are uploaded")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--publish", action="store_true", help="upload assets and publish once complete")
    parser.add_argument("--output", type=Path, help="write a local preview of the release body")
    parser.add_argument("assets", nargs="*", type=Path)
    args = parser.parse_args()
    download_rows(args.tag)  # Validate before using the tag in a file path.
    curated = (Path(__file__).resolve().parent.parent / "release-notes" / f"{args.tag}.md").read_text(encoding="utf-8")
    body = render_notes(args.tag, args.repo, curated)
    if args.output:
        args.output.write_text(body, encoding="utf-8")
    if args.publish:
        publish(args.tag, args.repo, args.assets, body)
    elif not args.output:
        print(body, end="")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(getattr(error, "stderr", None) or str(error), file=sys.stderr)
        sys.exit(1)
