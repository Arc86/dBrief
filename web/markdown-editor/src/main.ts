import "@milkdown/crepe/theme/common/prosemirror.css";
import "@milkdown/crepe/theme/common/reset.css";
import "@milkdown/crepe/theme/common/block-edit.css";
import "@milkdown/crepe/theme/common/cursor.css";
import "@milkdown/crepe/theme/common/link-tooltip.css";
import "@milkdown/crepe/theme/common/list-item.css";
import "@milkdown/crepe/theme/common/placeholder.css";
import "@milkdown/crepe/theme/common/table.css";
import "@milkdown/crepe/theme/common/toolbar.css";
import "./theme.css";
import { type BridgeMessage, type EditorAPI, mountEditor, shortcutFor } from "./editor";
import { measureHeight } from "./height";
import { animateReorder, displacements, snapshotBlocks } from "./reorder";

declare global {
  interface Window {
    dbrief?: EditorAPI;
    webkit?: { messageHandlers: { dbrief: { postMessage(message: unknown): void } } };
  }
}

const post = (message: BridgeMessage) => window.webkit?.messageHandlers.dbrief.postMessage(message);
const root = document.getElementById("editor")!;

window.addEventListener("keydown", (event) => {
  const name = shortcutFor(event);
  if (!name) return;
  event.preventDefault();
  // Flush the live document first: Milkdown's `changed` is debounced, so the
  // shortcut could otherwise overtake the last keystrokes (messages are ordered).
  if (name === "save" && window.dbrief) post({ type: "changed", markdown: window.dbrief.getMarkdown() });
  post({ type: "shortcut", name });
});

// The reported height covers the document and any open floating menu (slash
// menu, toolbar, link tooltip), which Crepe positions outside `#editor`'s box.
let reportedHeight = -1;
let pendingFrame = 0;
const reportHeight = () => {
  pendingFrame = 0;
  const value = measureHeight(root, window.scrollY);
  if (value === reportedHeight) return;
  reportedHeight = value;
  post({ type: "height", value });
};
const scheduleHeight = () => {
  if (pendingFrame === 0) pendingFrame = requestAnimationFrame(reportHeight);
};
new ResizeObserver(scheduleHeight).observe(root);
// Menus show/hide via `data-show` and move via inline `style`; mounting adds children.
new MutationObserver(scheduleHeight).observe(document.body, {
  subtree: true,
  childList: true,
  attributes: true,
  attributeFilter: ["data-show", "style", "class"],
});
// The block handle animates its position; measure again once it settles.
document.addEventListener("transitionend", scheduleHeight, true);

// Block drag: dim the dragged block while it moves, then glide the blocks that
// shifted into place and flash the one that landed. Capture phase runs before
// ProseMirror's own drop handler, so the snapshot is the pre-drop layout.
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
const endDrag = () => document.body.classList.remove("dbrief-dragging");
document.addEventListener("dragstart", () => document.body.classList.add("dbrief-dragging"), true);
document.addEventListener("dragend", endDrag, true);
document.addEventListener(
  "drop",
  () => {
    endDrag();
    const blocks = root.querySelector(".ProseMirror");
    if (!blocks) return;
    const before = snapshotBlocks(blocks);
    requestAnimationFrame(() => animateReorder(displacements(before, blocks), { reduceMotion: reduceMotion.matches }));
  },
  true,
);

// `ready` only after window.dbrief exists, so Swift's first calls always land.
mountEditor(root, post).then((api) => {
  window.dbrief = api;
  post({ type: "ready" });
});
