import type { MobileInputMode } from "./types";

const GUARD_ATTR = "data-wispterm-native-input-guard";
const PREV_READONLY_ATTR = "data-wispterm-prev-readonly";
const PREV_DISABLED_ATTR = "data-wispterm-prev-disabled";
const PREV_INPUTMODE_ATTR = "data-wispterm-prev-inputmode";
const PREV_TABINDEX_ATTR = "data-wispterm-prev-tabindex";

type NativeInputRoot = {
  querySelectorAll<E extends Element = Element>(selectors: string): ArrayLike<E>;
};

export function shouldBlockNativeTerminalInput(mobile: boolean, mode: MobileInputMode): boolean {
  return mobile && mode === "view";
}

export function setNativeTerminalInputBlocked(
  root: NativeInputRoot,
  blocked: boolean,
  activeElement: Element | null = document.activeElement,
): void {
  const inputs = root.querySelectorAll<HTMLInputElement | HTMLTextAreaElement>("textarea, input");
  for (let i = 0; i < inputs.length; i += 1) {
    const input = inputs[i];
    if (blocked) blockNativeInput(input, activeElement);
    else restoreNativeInput(input);
  }
}

function blockNativeInput(input: HTMLInputElement | HTMLTextAreaElement, activeElement: Element | null): void {
  if (!input.hasAttribute(GUARD_ATTR)) {
    input.setAttribute(GUARD_ATTR, "true");
    input.setAttribute(PREV_READONLY_ATTR, String(input.hasAttribute("readonly")));
    input.setAttribute(PREV_DISABLED_ATTR, String(input.hasAttribute("disabled")));
    const previousInputMode = input.getAttribute("inputmode");
    if (previousInputMode !== null) input.setAttribute(PREV_INPUTMODE_ATTR, previousInputMode);
    const previousTabIndex = input.getAttribute("tabindex");
    if (previousTabIndex !== null) input.setAttribute(PREV_TABINDEX_ATTR, previousTabIndex);
  }

  input.setAttribute("readonly", "true");
  input.setAttribute("disabled", "true");
  input.setAttribute("inputmode", "none");
  input.setAttribute("tabindex", "-1");
  if (activeElement === input) input.blur();
}

function restoreNativeInput(input: HTMLInputElement | HTMLTextAreaElement): void {
  if (!input.hasAttribute(GUARD_ATTR)) return;

  restoreBooleanAttribute(input, "readonly", PREV_READONLY_ATTR);
  restoreBooleanAttribute(input, "disabled", PREV_DISABLED_ATTR);
  restoreStringAttribute(input, "inputmode", PREV_INPUTMODE_ATTR);
  restoreStringAttribute(input, "tabindex", PREV_TABINDEX_ATTR);

  input.removeAttribute(GUARD_ATTR);
  input.removeAttribute(PREV_READONLY_ATTR);
  input.removeAttribute(PREV_DISABLED_ATTR);
  input.removeAttribute(PREV_INPUTMODE_ATTR);
  input.removeAttribute(PREV_TABINDEX_ATTR);
}

function restoreBooleanAttribute(
  input: HTMLInputElement | HTMLTextAreaElement,
  attr: string,
  previousAttr: string,
): void {
  if (input.getAttribute(previousAttr) === "true") input.setAttribute(attr, "true");
  else input.removeAttribute(attr);
}

function restoreStringAttribute(
  input: HTMLInputElement | HTMLTextAreaElement,
  attr: string,
  previousAttr: string,
): void {
  const previous = input.getAttribute(previousAttr);
  if (previous !== null) input.setAttribute(attr, previous);
  else input.removeAttribute(attr);
}
