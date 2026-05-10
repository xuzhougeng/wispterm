export const CANVAS_PAN_TAP_THRESHOLD = 8;

export type CanvasPoint = {
  x: number;
  y: number;
};

export type CanvasSize = {
  width: number;
  height: number;
};

export type CanvasPanOptions = {
  bottomGutter?: number;
};

export type ResizeCanvasPanOptions = CanvasPanOptions & {
  pan: CanvasPoint;
  previousViewport: CanvasSize | null;
  viewport: CanvasSize;
  canvas: CanvasSize;
};

export type CanvasPanDragInput = {
  mobile: boolean;
  isPrimary: boolean;
  button: number;
};

const BOTTOM_ANCHOR_EPSILON = 2;

export function clampCanvasPan(
  pan: CanvasPoint,
  viewport: CanvasSize,
  canvas: CanvasSize,
  options: CanvasPanOptions = {},
): CanvasPoint {
  const minX = Math.min(0, viewport.width - canvas.width);
  const minY = bottomPanLimit(viewport, canvas, options);
  return {
    x: clamp(pan.x, minX, 0),
    y: clamp(pan.y, minY, 0),
  };
}

export function defaultCanvasPan(
  viewport: CanvasSize,
  canvas: CanvasSize,
  options: CanvasPanOptions = {},
): CanvasPoint {
  return clampCanvasPan({ x: 0, y: bottomPanLimit(viewport, canvas, options) }, viewport, canvas, options);
}

export function resizeCanvasPan(options: ResizeCanvasPanOptions): CanvasPoint {
  const clamped = clampCanvasPan(options.pan, options.viewport, options.canvas, options);
  if (!shouldKeepBottomAnchored(options)) return clamped;

  return {
    x: clamped.x,
    y: defaultCanvasPan(options.viewport, options.canvas, options).y,
  };
}

export function panCanvasBy(
  startPan: CanvasPoint,
  delta: CanvasPoint,
  viewport: CanvasSize,
  canvas: CanvasSize,
): CanvasPoint {
  return clampCanvasPan(
    {
      x: startPan.x + delta.x,
      y: startPan.y + delta.y,
    },
    viewport,
    canvas,
  );
}

export function panCanvasByWheel(
  startPan: CanvasPoint,
  delta: CanvasPoint,
  viewport: CanvasSize,
  canvas: CanvasSize,
): CanvasPoint {
  return panCanvasBy(startPan, { x: -delta.x, y: -delta.y }, viewport, canvas);
}

export function isCanvasDrag(delta: CanvasPoint): boolean {
  return Math.hypot(delta.x, delta.y) > CANVAS_PAN_TAP_THRESHOLD;
}

export function shouldStartCanvasPanDrag(input: CanvasPanDragInput): boolean {
  if (!input.isPrimary) return false;
  return input.mobile ? input.button === 0 : input.button === 1;
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

function bottomPanLimit(viewport: CanvasSize, canvas: CanvasSize, options: CanvasPanOptions): number {
  const bottomGutter = Math.max(0, options.bottomGutter ?? 0);
  return Math.min(0, viewport.height - canvas.height - bottomGutter);
}

function shouldKeepBottomAnchored(options: ResizeCanvasPanOptions): boolean {
  if (!options.previousViewport) return true;
  const previousBottom = bottomPanLimit(options.previousViewport, options.canvas, options);
  const previousCanvasFit =
    options.canvas.height + Math.max(0, options.bottomGutter ?? 0) <= options.previousViewport.height;
  return previousCanvasFit || Math.abs(options.pan.y - previousBottom) <= BOTTOM_ANCHOR_EPSILON;
}
