import test from "node:test";
import assert from "node:assert/strict";

import {
  setNativeTerminalInputBlocked,
  shouldBlockNativeTerminalInput,
} from "../../src/client/terminal_input_guard";

class FakeInput {
  private attrs = new Map<string, string>();
  blurCalls = 0;

  constructor(readonly public tagName: string) {}

  hasAttribute(name: string): boolean {
    return this.attrs.has(name);
  }

  getAttribute(name: string): string | null {
    return this.attrs.get(name) ?? null;
  }

  setAttribute(name: string, value: string): void {
    this.attrs.set(name, value);
  }

  removeAttribute(name: string): void {
    this.attrs.delete(name);
  }

  blur(): void {
    this.blurCalls += 1;
  }
}

class FakeRoot {
  constructor(private readonly inputs: FakeInput[]) {}

  querySelectorAll(selector: string): FakeInput[] {
    assert.equal(selector, "textarea, input");
    return this.inputs;
  }
}

test("native terminal input is blocked only for mobile view mode", () => {
  assert.equal(shouldBlockNativeTerminalInput(true, "view"), true);
  assert.equal(shouldBlockNativeTerminalInput(true, "keys"), false);
  assert.equal(shouldBlockNativeTerminalInput(true, "text"), false);
  assert.equal(shouldBlockNativeTerminalInput(false, "view"), false);
});

test("blocking native terminal input disables and blurs xterm textareas", () => {
  const textarea = new FakeInput("TEXTAREA");
  textarea.setAttribute("inputmode", "text");
  const root = new FakeRoot([textarea]);

  setNativeTerminalInputBlocked(root as unknown as ParentNode, true, textarea as unknown as Element);

  assert.equal(textarea.getAttribute("readonly"), "true");
  assert.equal(textarea.getAttribute("disabled"), "true");
  assert.equal(textarea.getAttribute("inputmode"), "none");
  assert.equal(textarea.getAttribute("tabindex"), "-1");
  assert.equal(textarea.blurCalls, 1);
});

test("unblocking native terminal input restores previous attributes", () => {
  const textarea = new FakeInput("TEXTAREA");
  textarea.setAttribute("inputmode", "text");
  textarea.setAttribute("tabindex", "0");
  const root = new FakeRoot([textarea]);

  setNativeTerminalInputBlocked(root as unknown as ParentNode, true, null);
  setNativeTerminalInputBlocked(root as unknown as ParentNode, false, null);

  assert.equal(textarea.hasAttribute("readonly"), false);
  assert.equal(textarea.hasAttribute("disabled"), false);
  assert.equal(textarea.getAttribute("inputmode"), "text");
  assert.equal(textarea.getAttribute("tabindex"), "0");
});
