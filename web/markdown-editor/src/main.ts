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
  post({ type: "shortcut", name });
});

new ResizeObserver(() => {
  post({ type: "height", value: Math.ceil(root.getBoundingClientRect().height) });
}).observe(root);

// `ready` only after window.dbrief exists, so Swift's first calls always land.
mountEditor(root, post).then((api) => {
  window.dbrief = api;
  post({ type: "ready" });
});
