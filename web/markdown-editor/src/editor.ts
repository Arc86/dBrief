import { CrepeBuilder } from "@milkdown/crepe/builder";
import { blockEdit } from "@milkdown/crepe/feature/block-edit";
import { cursor } from "@milkdown/crepe/feature/cursor";
import { linkTooltip } from "@milkdown/crepe/feature/link-tooltip";
import { listItem } from "@milkdown/crepe/feature/list-item";
import { placeholder } from "@milkdown/crepe/feature/placeholder";
import { table } from "@milkdown/crepe/feature/table";
import { toolbar } from "@milkdown/crepe/feature/toolbar";
import { replaceAll } from "@milkdown/kit/utils";

export type BridgeMessage =
  | { type: "ready" }
  | { type: "loaded"; markdown: string }
  | { type: "changed"; markdown: string }
  | { type: "height"; value: number }
  | { type: "shortcut"; name: "save" | "cancel" };

export interface EditorAPI {
  setMarkdown(markdown: string): void;
  getMarkdown(): string;
  setTheme(vars: Record<string, string>): void;
  setReadOnly(readOnly: boolean): void;
  focus(): void;
}

/**
 * Mounts a tree-shaken Crepe editor (no images, LaTeX or CodeMirror) on `root`.
 * `changed` comes from Milkdown's listener, which is already debounced and only
 * fires when the serialized markdown actually differs.
 */
export async function mountEditor(root: HTMLElement, post: (message: BridgeMessage) => void): Promise<EditorAPI> {
  const builder = new CrepeBuilder({ root, defaultValue: "" });
  builder
    .addFeature(cursor)
    .addFeature(listItem)
    .addFeature(linkTooltip)
    .addFeature(placeholder, { text: "Write the summary, or type / for blocks", mode: "doc" })
    .addFeature(table)
    .addFeature(toolbar)
    .addFeature(blockEdit, {
      textGroup: { h4: null, h5: null, h6: null },
      advancedGroup: { image: null, codeBlock: null, math: null },
    });
  builder.on((listener) => {
    listener.markdownUpdated((_ctx, markdown) => post({ type: "changed", markdown }));
  });
  await builder.create();

  return {
    setMarkdown(markdown) {
      builder.editor.action(replaceAll(markdown));
      post({ type: "loaded", markdown: builder.getMarkdown() });
    },
    getMarkdown: () => builder.getMarkdown(),
    setTheme(vars) {
      for (const [name, value] of Object.entries(vars)) {
        document.documentElement.style.setProperty(name, value);
      }
    },
    setReadOnly(readOnly) {
      builder.setReadonly(readOnly);
    },
    focus() {
      root.querySelector<HTMLElement>(".ProseMirror")?.focus();
    },
  };
}

/** Maps a keydown to a bridge shortcut. Keys a menu already handled are ignored. */
export function shortcutFor(event: KeyboardEvent): "save" | "cancel" | null {
  if (event.defaultPrevented || event.isComposing) return null;
  const otherModifiers = event.shiftKey || event.altKey || event.ctrlKey;
  if (event.key === "s" && event.metaKey && !otherModifiers) return "save";
  if (event.key === "Escape" && !event.metaKey && !otherModifiers) return "cancel";
  return null;
}
