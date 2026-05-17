import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const responsiveCssUrl = new URL("../../src/client/styles/responsive.css", import.meta.url);
const consoleCssUrl = new URL("../../src/client/styles/console.css", import.meta.url);

test("mobile drawer keeps remote tabs usable on short screens", async () => {
  const css = await readFile(responsiveCssUrl, "utf8");
  const panelRule = declarationsForSelector(css, ".remote-tabs-panel").join("\n");
  const tabsRule = declarationsForSelector(css, ".remote-tabs").join("\n");

  assert.match(panelRule, /(?:flex:\s*0\s+0\s+auto|flex-shrink:\s*0)\s*;/);
  assert.match(tabsRule, /max-height\s*:/);
  assert.match(tabsRule, /overflow-y:\s*auto\s*;/);
});

test("xterm viewport remains scrollable for remote history", async () => {
  const css = await readFile(consoleCssUrl, "utf8");
  const viewportRule = declarationsForSelector(css, ".terminal-host .xterm-viewport").join("\n");

  assert.match(viewportRule, /overflow-y:\s*auto\s*!important\s*;/);
  assert.doesNotMatch(viewportRule, /overflow-y:\s*hidden\s*!important\s*;/);
  assert.match(viewportRule, /scrollbar-width:\s*none\s*;/);
});

test("terminal panels do not reserve redundant per-panel headers", async () => {
  const css = await readFile(consoleCssUrl, "utf8");
  const panelRule = declarationsForSelector(css, ".remote-panel").join("\n");
  const mountRule = declarationsForSelector(css, ".terminal-mount").join("\n");

  assert.match(panelRule, /grid-template-rows:\s*minmax\(0,\s*1fr\)\s*;/);
  assert.doesNotMatch(css, /\.panel-copy\b/);
  assert.match(mountRule, /border-radius:\s*var\(--radius\)\s*;/);
});

test("mobile view mode allows native terminal text selection", async () => {
  const css = await readFile(responsiveCssUrl, "utf8");
  const hostRule = declarationsForSelector(
    css,
    '.console-shell[data-mobile-input-mode="view"] .panels-stage[data-mobile-mode="single"] .terminal-host',
  ).join("\n");
  const xtermRule = declarationsForSelector(
    css,
    '.console-shell[data-mobile-input-mode="view"] .terminal-host .xterm',
  ).join("\n");

  assert.match(hostRule, /touch-action:\s*auto\s*;/);
  assert.match(xtermRule, /user-select:\s*text\s*;/);
  assert.match(xtermRule, /-webkit-user-select:\s*text\s*;/);
});

function declarationsForSelector(css: string, selector: string): string[] {
  const rulePattern = /([^{}]+)\{([^{}]*)\}/g;
  const matches: string[] = [];
  for (const match of css.matchAll(rulePattern)) {
    const selectors = match[1]
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean);
    if (selectors.includes(selector)) matches.push(match[2]);
  }
  if (matches.length > 0) return matches;
  throw new Error(`Missing CSS rule for ${selector}`);
}
