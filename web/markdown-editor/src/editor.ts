import { CrepeBuilder } from "@milkdown/crepe/builder";
import { blockEdit } from "@milkdown/crepe/feature/block-edit";
import { cursor } from "@milkdown/crepe/feature/cursor";
import { linkTooltip } from "@milkdown/crepe/feature/link-tooltip";
import { listItem } from "@milkdown/crepe/feature/list-item";
import { placeholder } from "@milkdown/crepe/feature/placeholder";
import { table } from "@milkdown/crepe/feature/table";
import { toolbar } from "@milkdown/crepe/feature/toolbar";
import { editorViewCtx } from "@milkdown/kit/core";
import { replaceAll } from "@milkdown/kit/utils";
import { createLiveRegion, labelEditor, moveBlock, moveDirectionFor, syncSlashMenu } from "./a11y";
import { englishStrings, type EditorStrings } from "./strings";

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
export async function mountEditor(
  root: HTMLElement,
  post: (message: BridgeMessage) => void,
  strings: EditorStrings = englishStrings,
): Promise<EditorAPI> {
  const builder = new CrepeBuilder({ root, defaultValue: "" });
  builder
    .addFeature(cursor)
    .addFeature(listItem)
    .addFeature(linkTooltip, { inputPlaceholder: strings.linkPlaceholder })
    .addFeature(placeholder, { text: strings.placeholder, mode: "doc" })
    .addFeature(table)
    .addFeature(toolbar, {
      boldLabel: strings.bold,
      italicLabel: strings.italic,
      strikethroughLabel: strings.strikethrough,
      codeLabel: strings.inlineCode,
      linkLabel: strings.link,
    })
    .addFeature(blockEdit, {
      textGroup: {
        label: strings.textGroup,
        text: { label: strings.text },
        h1: { label: strings.heading1 },
        h2: { label: strings.heading2 },
        h3: { label: strings.heading3 },
        h4: null,
        h5: null,
        h6: null,
        quote: { label: strings.quote },
        divider: { label: strings.divider },
      },
      listGroup: {
        label: strings.listGroup,
        bulletList: { label: strings.bulletList },
        orderedList: { label: strings.orderedList },
        taskList: { label: strings.taskList },
      },
      advancedGroup: { label: strings.advancedGroup, image: null, codeBlock: null, table: { label: strings.table }, math: null },
    });
  builder.on((listener) => {
    listener.markdownUpdated((_ctx, markdown) => post({ type: "changed", markdown }));
  });
  await builder.create();

  const editable = root.querySelector<HTMLElement>(".ProseMirror");
  if (editable) labelEditor(editable, strings.editorLabel);
  const say = createLiveRegion(document);

  // ⌥⇧↑ / ⌥⇧↓ move the block with the cursor, so reordering needs no drag.
  root.addEventListener(
    "keydown",
    (event) => {
      const direction = moveDirectionFor(event);
      if (direction === null) return;
      const view = builder.editor.ctx.get(editorViewCtx);
      if (!view.editable) return;
      event.preventDefault();
      const tr = moveBlock(view.state, direction);
      if (!tr) return;
      view.dispatch(tr);
      say(direction === -1 ? strings.blockMovedUp : strings.blockMovedDown);
    },
    true,
  );

  // The slash menu reads as a list of blocks; the highlighted one is spoken.
  let spokenBlock: string | null = null;
  new MutationObserver(() => {
    const menu = document.querySelector(".milkdown-slash-menu");
    if (!menu || !editable) return;
    const highlighted = syncSlashMenu(menu, editable, strings.blocksLabel);
    if (highlighted && highlighted !== spokenBlock) say(highlighted);
    spokenBlock = highlighted;
  }).observe(document.body, { subtree: true, childList: true, attributes: true, attributeFilter: ["data-show", "class"] });

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
