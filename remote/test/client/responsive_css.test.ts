import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const responsiveCssUrl = new URL("../../src/client/styles/responsive.css", import.meta.url);
const consoleCssUrl = new URL("../../src/client/styles/console.css", import.meta.url);
const consoleViewUrl = new URL("../../src/client/views/console.ts", import.meta.url);

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

test("mobile view mode keeps drag handling while allowing native terminal text selection", async () => {
  const css = await readFile(responsiveCssUrl, "utf8");
  const hostRule = declarationsForSelector(
    css,
    '.console-shell[data-mobile-input-mode="view"] .panels-stage[data-mobile-mode="single"] .terminal-host',
  ).join("\n");
  const xtermRule = declarationsForSelector(
    css,
    '.console-shell[data-mobile-input-mode="view"] .terminal-host .xterm',
  ).join("\n");

  assert.match(hostRule, /touch-action:\s*none\s*;/);
  assert.match(xtermRule, /user-select:\s*text\s*;/);
  assert.match(xtermRule, /-webkit-user-select:\s*text\s*;/);
});

test("mobile top bar uses compact status controls instead of large mode buttons", async () => {
  const css = await readFile(responsiveCssUrl, "utf8");
  const markup = await readFile(consoleViewUrl, "utf8");
  const barRule = declarationsForSelector(css, ".mobile-bar").join("\n");
  const controlsRule = declarationsForSelector(css, ".mobile-chrome-controls").join("\n");
  const modeRule = declarationsForSelector(css, ".mobile-input-mode-toggle").join("\n");
  const zoomRule = declarationsForSelector(css, ".mobile-zoom-toggle").join("\n");
  const keyboardRule = declarationsForSelector(css, ".mobile-keyboard-toggle").join("\n");

  assert.match(markup, /class="mobile-chrome-controls"/);
  assert.match(markup, /mobileInputModeCompactLabel/);
  assert.match(markup, /mobileVisualZoomCompactLabel/);
  assert.match(barRule, /grid-template-columns:\s*40px\s+minmax\(0,\s*1fr\)\s+auto\s*;/);
  assert.doesNotMatch(barRule, /52px|58px/);
  assert.match(controlsRule, /display:\s*flex\s*;/);
  for (const rule of [modeRule, zoomRule, keyboardRule]) {
    assert.match(rule, /height:\s*32px\s*;/);
    assert.doesNotMatch(rule, /height:\s*42px\s*;/);
  }
});

test("status lights expose clickable red green and yellow latency states", async () => {
  const css = await readFile(consoleCssUrl, "utf8");
  const markup = await readFile(consoleViewUrl, "utf8");
  const dotRule = declarationsForSelector(css, ".status-dot").join("\n");
  const pipRule = declarationsForSelector(css, ".status-pip").join("\n");
  const onlineDotRule = declarationsForSelector(css, '.status-dot[data-state="online"]').join("\n");
  const highLatencyDotRule = declarationsForSelector(css, '.status-dot[data-state="high-latency"]').join("\n");
  const highLatencyPipRule = declarationsForSelector(css, '.status-pip[data-state="high-latency"]').join("\n");

  assert.match(markup, /button type="button" class="status-dot" id="status-dot"/);
  assert.match(markup, /button type="button" class="status-pip" id="mobile-status-pip"/);
  assert.match(markup, /id="status-latency-detail"/);
  assert.match(markup, /id="mobile-status-latency"/);
  assert.match(dotRule, /background:\s*var\(--danger\)\s*;/);
  assert.match(pipRule, /background:\s*var\(--danger\)\s*;/);
  assert.match(onlineDotRule, /background:\s*var\(--ok\)\s*;/);
  assert.match(highLatencyDotRule, /background:\s*var\(--warning\)\s*;/);
  assert.match(highLatencyPipRule, /background:\s*var\(--warning\)\s*;/);
});

test("mobile surface selector moves into the top bar and removes the second chrome row", async () => {
  const css = await readFile(responsiveCssUrl, "utf8");
  const markup = await readFile(consoleViewUrl, "utf8");
  const workspaceRule = declarationsForSelector(css, ".workspace").join("\n");
  const terminalPanelRule = declarationsForSelector(css, ".terminal-panel").join("\n");
  const selectorRule = declarationsForSelector(css, ".mobile-surface-selector").join("\n");
  const stripRule = declarationsForSelector(css, ".mobile-surface-strip").join("\n");

  assert.match(markup, /class="mobile-bar-main"[\s\S]*id="mobile-surface-selector"[\s\S]*class="mobile-chrome-controls"/);
  assert.match(markup, /id="mobile-surface-strip"/);
  assert.match(markup, /id="mobile-surface-menu-toggle"/);
  assert.match(markup, /id="mobile-surface-menu"/);
  assert.match(workspaceRule, /grid-template-rows:\s*auto\s+minmax\(0,\s*1fr\)\s*;/);
  assert.match(terminalPanelRule, /grid-row:\s*2\s*;/);
  assert.match(selectorRule, /min-width:\s*0\s*;/);
  assert.match(stripRule, /overflow:\s*hidden\s*;/);
});

test("mobile surface selector collapses into a menu before crowding right controls", async () => {
  const css = await readFile(responsiveCssUrl, "utf8");
  const markup = await readFile(consoleViewUrl, "utf8");
  const collapsedStripRule = declarationsForSelector(
    css,
    '.mobile-surface-selector[data-collapsed="true"] .mobile-surface-strip',
  ).join("\n");
  const collapsedToggleRule = declarationsForSelector(
    css,
    '.mobile-surface-selector[data-collapsed="true"] .mobile-surface-menu-toggle',
  ).join("\n");
  const menuRule = declarationsForSelector(css, ".mobile-surface-menu").join("\n");

  assert.match(markup, /syncMobileSurfaceSelectorCollapse/);
  assert.match(markup, /scrollWidth/);
  assert.match(markup, /clientWidth/);
  assert.match(collapsedStripRule, /display:\s*none\s*;/);
  assert.match(collapsedToggleRule, /display:\s*inline-flex\s*;/);
  assert.match(menuRule, /position:\s*absolute\s*;/);
});

test("mobile surface menu uses an opaque layer over terminal content", async () => {
  const css = await readFile(responsiveCssUrl, "utf8");
  const barRule = declarationsForSelector(css, ".mobile-bar").join("\n");
  const menuRule = declarationsForSelector(css, ".mobile-surface-menu").join("\n");

  assert.match(barRule, /position:\s*relative\s*;/);
  assert.match(barRule, /z-index:\s*(?:[5-9][0-9]|[1-9][0-9]{2,})\s*;/);
  assert.match(barRule, /overflow:\s*visible\s*;/);
  assert.match(menuRule, /z-index:\s*(?:[4-9][0-9]|[1-9][0-9]{2,})\s*;/);
  assert.match(menuRule, /background:\s*var\(--panel-strong\)\s*;/);
  assert.doesNotMatch(menuRule, /surface-overlay/);
});

test("mobile surface dropdown stays right-aligned near the chrome controls", async () => {
  const css = await readFile(responsiveCssUrl, "utf8");
  const selectorRule = declarationsForSelector(css, ".mobile-surface-selector").join("\n");
  const collapsedSelectorRule = declarationsForSelector(
    css,
    '.mobile-surface-selector[data-collapsed="true"]',
  ).join("\n");
  const menuRule = declarationsForSelector(css, ".mobile-surface-menu").join("\n");

  assert.match(selectorRule, /display:\s*flex\s*;/);
  assert.match(selectorRule, /justify-content:\s*flex-start\s*;/);
  assert.match(collapsedSelectorRule, /justify-content:\s*flex-end\s*;/);
  assert.match(menuRule, /right:\s*0\s*;/);
  assert.match(menuRule, /left:\s*auto\s*;/);
});

test("mobile canvas scrollbar is anchored to the viewport during visual zoom", async () => {
  const css = await readFile(responsiveCssUrl, "utf8");
  const scrollbarRule = declarationsForSelector(
    css,
    '.panels-stage[data-mobile-mode="single"] .canvas-scrollbar',
  ).join("\n");
  const visibleRule = declarationsForSelector(
    css,
    '.panels-stage[data-mobile-mode="single"] .canvas-scrollbar[data-visible="true"]',
  ).join("\n");

  assert.match(scrollbarRule, /right:\s*5px\s*;/);
  assert.match(scrollbarRule, /pointer-events:\s*none\s*;/);
  assert.match(visibleRule, /display:\s*block\s*;/);
});

test("mobile view mode keeps the keyboard status control subdued", async () => {
  const css = await readFile(responsiveCssUrl, "utf8");
  const keyboardViewRule = declarationsForSelector(
    css,
    '.console-shell[data-mobile-input-mode="view"] .mobile-keyboard-toggle',
  ).join("\n");

  assert.match(keyboardViewRule, /opacity:\s*0\.[0-9]+\s*;/);
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
