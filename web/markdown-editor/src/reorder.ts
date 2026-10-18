/**
 * ProseMirror moves a dragged block in one jump. To make the reorder visible,
 * record every top-level block's position before the drop, then let the blocks
 * that shifted glide from their old spot to the new one (FLIP) and flash the
 * block that landed. ProseMirror keeps the DOM of unchanged blocks, so element
 * identity tells which ones merely moved; the dropped block is re-created.
 */
export interface BlockPosition {
  element: Element;
  top: number;
}

export interface Reorder {
  moved: { element: HTMLElement; dy: number }[];
  arrived: HTMLElement[];
}

export const glideMs = 200;
export const droppedClass = "dbrief-dropped";

export function snapshotBlocks(container: Element): BlockPosition[] {
  return Array.from(container.children, (element) => ({ element, top: element.getBoundingClientRect().top }));
}

/** Blocks that moved at least a pixel, with their offset back to the old spot, and blocks that are new. */
export function displacements(before: readonly BlockPosition[], container: Element): Reorder {
  const previous = new Map(before.map((entry) => [entry.element, entry.top]));
  const reorder: Reorder = { moved: [], arrived: [] };
  for (const element of Array.from(container.children) as HTMLElement[]) {
    const oldTop = previous.get(element);
    if (oldTop === undefined) {
      reorder.arrived.push(element);
      continue;
    }
    const dy = oldTop - element.getBoundingClientRect().top;
    if (Math.abs(dy) >= 1) reorder.moved.push({ element, dy });
  }
  return reorder;
}

export function animateReorder({ moved, arrived }: Reorder, options: { reduceMotion?: boolean } = {}): void {
  for (const element of arrived) {
    element.classList.remove(droppedClass);
    void element.offsetWidth; // restart the flash if the class was already there
    element.classList.add(droppedClass);
    element.addEventListener("animationend", () => element.classList.remove(droppedClass), { once: true });
  }
  if (options.reduceMotion || moved.length === 0) return;

  for (const { element, dy } of moved) {
    element.style.transition = "none";
    element.style.transform = `translateY(${dy}px)`;
  }
  // One forced layout so the starting offsets apply before the transition.
  void moved[0].element.offsetWidth;
  requestAnimationFrame(() => {
    for (const { element } of moved) {
      element.style.transition = `transform ${glideMs}ms cubic-bezier(0.2, 0, 0, 1)`;
      element.style.transform = "";
      element.addEventListener(
        "transitionend",
        () => {
          element.style.transition = "";
        },
        { once: true },
      );
    }
  });
}
