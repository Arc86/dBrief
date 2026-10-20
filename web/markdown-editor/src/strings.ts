/**
 * Every piece of text the editor shows or speaks. The app injects localized
 * values as `window.dbriefStrings` before this bundle runs (see
 * `MarkdownEditorStrings` in Swift); anything missing falls back to English.
 */
export interface EditorStrings {
  placeholder: string;
  editorLabel: string;
  blocksLabel: string;
  blockMovedUp: string;
  blockMovedDown: string;
  textGroup: string;
  text: string;
  heading1: string;
  heading2: string;
  heading3: string;
  quote: string;
  divider: string;
  listGroup: string;
  bulletList: string;
  orderedList: string;
  taskList: string;
  advancedGroup: string;
  table: string;
  bold: string;
  italic: string;
  strikethrough: string;
  inlineCode: string;
  link: string;
  linkPlaceholder: string;
}

export const englishStrings: EditorStrings = {
  placeholder: "Write the summary, or type / for blocks",
  editorLabel: "Summary",
  blocksLabel: "Blocks",
  blockMovedUp: "Block moved up",
  blockMovedDown: "Block moved down",
  textGroup: "Text",
  text: "Text",
  heading1: "Heading 1",
  heading2: "Heading 2",
  heading3: "Heading 3",
  quote: "Quote",
  divider: "Divider",
  listGroup: "List",
  bulletList: "Bullet List",
  orderedList: "Ordered List",
  taskList: "Task List",
  advancedGroup: "Advanced",
  table: "Table",
  bold: "Bold",
  italic: "Italic",
  strikethrough: "Strikethrough",
  inlineCode: "Inline code",
  link: "Link",
  linkPlaceholder: "Paste link...",
};

/** The injected strings over the English defaults; non-string values are ignored. */
export function resolveStrings(injected: unknown): EditorStrings {
  const result = { ...englishStrings };
  if (injected && typeof injected === "object") {
    for (const key of Object.keys(englishStrings) as (keyof EditorStrings)[]) {
      const value = (injected as Record<string, unknown>)[key];
      if (typeof value === "string" && value.length > 0) result[key] = value;
    }
  }
  return result;
}
