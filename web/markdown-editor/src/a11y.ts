import { type EditorState, TextSelection, type Transaction } from "@milkdown/kit/prose/state";

/** Names the editable area for VoiceOver; ProseMirror leaves it unlabelled. */
export function labelEditor(editable: HTMLElement): void {
  editable.setAttribute("role", "textbox");
  editable.setAttribute("aria-multiline", "true");
  editable.setAttribute("aria-label", "Summary");
}

/**
 * Moves the top-level block holding the cursor one place up (-1) or down (1),
 * keeping the cursor in it: the keyboard twin of dragging a block's handle.
 * Returns null at either end.
 */
export function moveBlock(state: EditorState, direction: -1 | 1): Transaction | null {
  const { $from, from, to } = state.selection;
  if ($from.depth < 1) return null;
  const index = $from.index(0);
  const target = index + direction;
  if (target < 0 || target >= state.doc.childCount) return null;

  const block = state.doc.child(index);
  const neighbour = state.doc.child(target);
  const blockStart = $from.before(1);
  const tr = state.tr;
  let shift: number;
  if (direction === -1) {
    const start = blockStart - neighbour.nodeSize;
    tr.replaceWith(start, blockStart + block.nodeSize, [block, neighbour]);
    shift = -neighbour.nodeSize;
  } else {
    tr.replaceWith(blockStart, blockStart + block.nodeSize + neighbour.nodeSize, [neighbour, block]);
    shift = neighbour.nodeSize;
  }
  const blockEnd = blockStart + block.nodeSize;
  // A selection reaching past the block can't follow it; land at its start instead.
  const inside = from >= blockStart && to <= blockEnd;
  const anchor = inside ? from + shift : blockStart + shift + 1;
  const head = inside ? to + shift : anchor;
  tr.setSelection(TextSelection.create(tr.doc, anchor, head));
  return tr.scrollIntoView();
}

/** ⌥⇧↑ / ⌥⇧↓, the block-move shortcuts. */
export function moveDirectionFor(event: KeyboardEvent): -1 | 1 | null {
  if (!event.altKey || !event.shiftKey || event.metaKey || event.ctrlKey || event.defaultPrevented) return null;
  if (event.key === "ArrowUp") return -1;
  if (event.key === "ArrowDown") return 1;
  return null;
}

/**
 * Gives Crepe's slash menu listbox semantics: the groups become a listbox, each
 * entry an option, and the highlighted entry is selected and set as the editor's
 * active descendant. Returns the highlighted entry's label, or null when closed.
 */
export function syncSlashMenu(menu: Element, editable: HTMLElement): string | null {
  const open = menu.getAttribute("data-show") === "true";
  const list = menu.querySelector(".menu-groups");
  if (!open || !list) {
    editable.removeAttribute("aria-activedescendant");
    editable.removeAttribute("aria-controls");
    return null;
  }
  list.setAttribute("role", "listbox");
  list.setAttribute("aria-label", "Blocks");
  if (!list.id) list.id = "dbrief-block-menu";
  let highlighted: string | null = null;
  for (const item of Array.from(list.querySelectorAll<HTMLElement>("li[data-index]"))) {
    item.setAttribute("role", "option");
    item.id = `dbrief-block-${item.dataset.index}`;
    const selected = item.classList.contains("hover");
    item.setAttribute("aria-selected", String(selected));
    if (selected) {
      highlighted = item.textContent?.trim() || null;
      editable.setAttribute("aria-activedescendant", item.id);
    }
  }
  editable.setAttribute("aria-controls", list.id);
  return highlighted;
}

/** A visually hidden polite live region for short spoken updates. */
export function createLiveRegion(doc: Document): (text: string) => void {
  const region = doc.createElement("div");
  region.setAttribute("aria-live", "polite");
  region.setAttribute("role", "status");
  region.style.cssText =
    "position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;";
  doc.body.appendChild(region);
  return (text) => {
    // Clear first so the same text twice is still spoken.
    region.textContent = "";
    requestAnimationFrame(() => {
      region.textContent = text;
    });
  };
}
