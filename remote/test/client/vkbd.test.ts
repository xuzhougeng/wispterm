import test from "node:test";
import assert from "node:assert/strict";

import { bindVirtualKeyboard, setVirtualKeyboardSender } from "../../src/client/vkbd";
import { state } from "../../src/client/state";

type Listener = (event: { preventDefault(): void }) => void;

class FakeButton {
  dataset: Record<string, string>;
  private listeners = new Map<string, Listener[]>();

  constructor(dataset: Record<string, string>) {
    this.dataset = dataset;
  }

  addEventListener(type: string, listener: Listener): void {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), listener]);
  }

  click(): void {
    const event = { preventDefault() {} };
    for (const listener of this.listeners.get("click") ?? []) listener(event);
  }
}

class FakeKeyboard {
  dataset: Record<string, string> = { modCtrl: "false", modAlt: "false" };

  constructor(private buttons: FakeButton[]) {}

  querySelectorAll(selector: string): FakeButton[] {
    if (selector === ".vkbd-key") return this.buttons;
    if (selector === "[data-vk-mod]") return this.buttons.filter((button) => button.dataset.vkMod);
    return [];
  }
}

test("sticky modifiers clear after special keys", () => {
  const ctrl = new FakeButton({ vkMod: "ctrl", active: "false" });
  const enter = new FakeButton({ vkKey: "enter" });
  const text = new FakeButton({ vkText: "c" });
  const keyboard = new FakeKeyboard([ctrl, enter, text]);

  Object.defineProperty(globalThis, "document", {
    configurable: true,
    value: {
      querySelector(selector: string): FakeKeyboard | null {
        return selector === "#vkbd" ? keyboard : null;
      },
    },
  });

  const sent: string[] = [];
  state.selectedSurfaceId = "surface-a";
  setVirtualKeyboardSender((_surfaceId, data) => sent.push(data));
  bindVirtualKeyboard(() => {});

  ctrl.click();
  enter.click();
  text.click();

  assert.deepEqual(sent, ["\r", "c"]);
  assert.equal(keyboard.dataset.modCtrl, "false");
  assert.equal(ctrl.dataset.active, "false");
});
