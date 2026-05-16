---
name: web
description: Browse or inspect live web pages.
---

# Web

Use this skill when the user asks to inspect, navigate, extract from, or act on
live web pages. Prefer read-only inspection unless the user explicitly asks to
interact with the page or submit data.

## GenericAgent-inspired browser workflow

This default workflow is adapted for Phantty from GenericAgent's browser-agent
pattern: keep the browser state real, keep observations compact, use precise
page execution when available, and verify every page-changing action.

1. Use the user's existing browser/session context when the available tools
   support it. Logged-in state is often more valuable than a clean sandbox.
2. Capture a compact text or DOM snapshot before acting. Prefer the main page
   content, active dialog, focused form, and visible controls over full raw HTML.
3. For interaction, prefer precise selectors, small JavaScript snippets, or
   browser-native automation over broad coordinate guesses. If a click or form
   change is sensitive, assume synthetic events may be rejected and verify the
   result.
4. After every action, inspect the delta: changed text, changed DOM region,
   navigation, reload, new tab, toast, or validation error.
5. Avoid repeated full-page scans. Reuse tab identity, URLs, visible labels, and
   earlier observations; rescan only after navigation or meaningful page change.
6. If the browser tool layer cannot reach a page, iframe, upload control, or
   trusted event path, state the limitation and switch to an available fallback
   such as terminal HTTP requests, local scripts, or user confirmation.

## Reusable JavaScript snippets

Use these snippets with the available browser JavaScript execution tool when
that tool exists. They are intentionally compact: paste the helper into the
same execution as the action that needs it, then return JSON-shaped data.

### Compact page snapshot

```javascript
function phanttyCompactSnapshot(limit = 120) {
  const text = (node) => (node?.innerText || node?.textContent || "")
    .replace(/\s+/g, " ")
    .trim();
  const isVisible = (el) => {
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    return rect.width > 1 &&
      rect.height > 1 &&
      style.display !== "none" &&
      style.visibility !== "hidden" &&
      Number(style.opacity || 1) > 0;
  };
  const short = (value, max = 180) => {
    value = String(value || "").replace(/\s+/g, " ").trim();
    return value.length > max ? value.slice(0, max) + " ..." : value;
  };
  const describe = (el) => {
    const rect = el.getBoundingClientRect();
    return {
      tag: el.tagName.toLowerCase(),
      id: el.id || undefined,
      name: el.getAttribute("name") || undefined,
      type: el.getAttribute("type") || undefined,
      role: el.getAttribute("role") || undefined,
      aria: el.getAttribute("aria-label") || undefined,
      placeholder: el.getAttribute("placeholder") || undefined,
      value: /^(input|textarea|select)$/i.test(el.tagName) ? short(el.value, 80) : undefined,
      href: el.href ? short(el.href, 160) : undefined,
      label: short(el.getAttribute("aria-label") || el.getAttribute("title") || text(el), 140),
      rect: {
        x: Math.round(rect.x),
        y: Math.round(rect.y),
        w: Math.round(rect.width),
        h: Math.round(rect.height)
      }
    };
  };
  const controlSelector = [
    "dialog",
    "[role='dialog']",
    "[aria-modal='true']",
    "button",
    "a[href]",
    "input:not([type='hidden'])",
    "textarea",
    "select",
    "[role='button']",
    "[role='menuitem']",
    "[contenteditable='true']"
  ].join(",");
  const controls = Array.from(document.querySelectorAll(controlSelector))
    .filter(isVisible)
    .slice(0, limit)
    .map(describe);
  const headings = Array.from(document.querySelectorAll("h1,h2,h3,[role='heading']"))
    .filter(isVisible)
    .slice(0, 40)
    .map((el) => short(text(el), 140))
    .filter(Boolean);
  return {
    url: location.href,
    title: document.title,
    active: document.activeElement ? describe(document.activeElement) : null,
    headings,
    controls,
    bodyText: short(text(document.body), 4000)
  };
}
return phanttyCompactSnapshot();
```

### Action with before/after delta

Paste `phanttyCompactSnapshot` before this helper. Replace the target-finding
logic with the page-specific action.

```javascript
async function phanttyWithDelta(action, waitMs = 800) {
  const before = phanttyCompactSnapshot(80);
  const result = await action();
  await new Promise((resolve) => setTimeout(resolve, waitMs));
  const after = phanttyCompactSnapshot(80);
  return {
    result,
    urlChanged: before.url !== after.url,
    titleChanged: before.title !== after.title,
    textChanged: before.bodyText !== after.bodyText,
    beforeUrl: before.url,
    after
  };
}

return await phanttyWithDelta(async () => {
  const targetText = "Continue";
  const target = Array.from(document.querySelectorAll("button,a,[role='button']"))
    .find((el) => (el.innerText || el.textContent || "").trim().includes(targetText));
  if (!target) throw new Error("Target not found: " + targetText);
  target.click();
  return { clicked: targetText };
});
```

### Framework-friendly value setter

Use this for simple forms. Always inspect the result afterward because some
sites reject synthetic events or require trusted input paths.

```javascript
function phanttySetValue(selector, value) {
  const el = document.querySelector(selector);
  if (!el) throw new Error("Element not found: " + selector);
  const proto = el.tagName === "TEXTAREA"
    ? HTMLTextAreaElement.prototype
    : HTMLInputElement.prototype;
  const descriptor = Object.getOwnPropertyDescriptor(proto, "value");
  if (descriptor && descriptor.set) descriptor.set.call(el, value);
  else el.value = value;
  el.dispatchEvent(new Event("input", { bubbles: true }));
  el.dispatchEvent(new Event("change", { bubbles: true }));
  return { selector, value: el.value };
}
return phanttySetValue("input[name='q']", "search terms");
```
