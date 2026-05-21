import assert from "node:assert/strict";
import fs from "node:fs";

const workflow = fs.readFileSync(".github/workflows/windows-release.yml", "utf8");
const build = fs.readFileSync("build.zig", "utf8");
const packageScript = fs.readFileSync("packaging/windows/package.ps1", "utf8");
const readme = fs.readFileSync("README.md", "utf8");

assert.match(packageScript, /portable-no-webview/);
assert.match(packageScript, /-Dwebview=false/);
assert.match(packageScript, /Portable no-WebView build:/);
assert.match(packageScript, /\$sourcePluginsDir = Join-Path \(Split-Path -Parent \$BinaryPath\) 'plugins'/);

assert.match(build, /\.source_dir = b\.path\("plugins"\)/);
assert.match(build, /\.install_subdir = "plugins"/);
assert.ok(fs.existsSync("plugins/skills/inspect-computer-config/SKILL.md"));
assert.ok(fs.existsSync("plugins/skills/inspect-computer-config/scripts/inspect_computer_config.py"));
assert.ok(!fs.existsSync("plugins/computer-config/skills/inspect-computer-config/SKILL.md"));

assert.match(workflow, /portable-no-webview/);
assert.match(workflow, /phantty-windows-portable-no-webview-\$tag\.zip/);
assert.match(workflow, /Upload portable no-WebView artifact/);
assert.match(workflow, /Portable no-WebView:/);
assert.match(workflow, /plugins\\skills\\inspect-computer-config\\SKILL\.md/);
assert.match(workflow, /plugins\\skills\\inspect-computer-config\\scripts\\inspect_computer_config\.py/);

assert.match(readme, /portable-no-webview/);
assert.match(readme, /phantty-windows-portable-no-webview-vX\.Y\.Z\.zip/);
