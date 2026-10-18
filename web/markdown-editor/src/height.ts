/**
 * Crepe's floating UI (slash menu, block handle, selection toolbar, link
 * tooltips) is absolutely positioned, so it never grows `#editor`. The web view
 * is exactly as tall as the height we report, so anything below the last line
 * would be clipped unless the reported height also covers the visible menus.
 */
export const floatingSelectors = [
  ".milkdown-slash-menu",
  ".milkdown-block-handle",
  ".milkdown-toolbar",
  ".milkdown-link-preview",
  ".milkdown-link-edit",
] as const;

/** Extra room below a floating menu so its shadow is not clipped. */
export const floatingMargin = 12;

export interface FloatingBox {
  /** Bottom edge in document coordinates. */
  bottom: number;
  visible: boolean;
}

/**
 * Pure height rule: the editor's bottom edge, or the lowest visible floating
 * element plus `margin`, whichever is lower on the page — rounded up.
 * The margin only applies to menus, so a plain document keeps its exact height.
 */
export function contentHeight(editorBottom: number, floating: readonly FloatingBox[], margin = floatingMargin): number {
  let height = editorBottom;
  for (const box of floating) {
    if (box.visible) height = Math.max(height, box.bottom + margin);
  }
  return Math.max(0, Math.ceil(height));
}

/**
 * Crepe hides its menus with `data-show="false"` (via `display: none`, or
 * `opacity: 0` for the block handle). A shown element with an empty box
 * (not rendered yet) does not count either.
 */
export function isFloatingVisible(element: Element, rect: { width: number; height: number }): boolean {
  if (element.getAttribute("data-show") === "false") return false;
  return rect.width > 0 || rect.height > 0;
}

/**
 * Measures `root` and the floating menus in document coordinates. Menus are
 * looked up document-wide: Crepe mounts them beside the ProseMirror view, but a
 * provider may also fall back to `document.body`.
 */
export function measureHeight(root: HTMLElement, scrollY = 0): number {
  const floating = Array.from(root.ownerDocument.querySelectorAll(floatingSelectors.join(","))).map((element) => {
    const rect = element.getBoundingClientRect();
    return { bottom: rect.bottom + scrollY, visible: isFloatingVisible(element, rect) };
  });
  return contentHeight(root.getBoundingClientRect().bottom + scrollY, floating);
}
