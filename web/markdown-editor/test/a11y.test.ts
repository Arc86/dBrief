import { describe, expect, test } from "vitest";
import { Schema } from "@milkdown/kit/prose/model";
import { EditorState, TextSelection } from "@milkdown/kit/prose/state";
import { labelEditor, moveBlock, moveDirectionFor, syncSlashMenu } from "../src/a11y";

describe("labelEditor", () => {
  test("names the editable area as a multi-line text box", () => {
    const el = document.createElement("div");
    labelEditor(el);
    expect(el.getAttribute("role")).toBe("textbox");
    expect(el.getAttribute("aria-multiline")).toBe("true");
    expect(el.getAttribute("aria-label")).toBe("Summary");
  });
});

describe("moveDirectionFor", () => {
  const key = (key: string, init: KeyboardEventInit = {}) => new KeyboardEvent("keydown", { key, ...init });
  test("only Option-Shift-arrows move blocks", () => {
    expect(moveDirectionFor(key("ArrowUp", { altKey: true, shiftKey: true }))).toBe(-1);
    expect(moveDirectionFor(key("ArrowDown", { altKey: true, shiftKey: true }))).toBe(1);
    expect(moveDirectionFor(key("ArrowDown", { altKey: true }))).toBeNull();
    expect(moveDirectionFor(key("ArrowDown", { altKey: true, shiftKey: true, metaKey: true }))).toBeNull();
  });
});

describe("moveBlock", () => {
  const schema = new Schema({
    nodes: {
      doc: { content: "block+" },
      paragraph: { group: "block", content: "text*", toDOM: () => ["p", 0] },
      text: {},
    },
  });
  const state = (...texts: string[]) =>
    EditorState.create({ doc: schema.node("doc", null, texts.map((t) => schema.node("paragraph", null, schema.text(t)))) });
  const texts = (s: EditorState) => Array.from({ length: s.doc.childCount }, (_, i) => s.doc.child(i).textContent);

  test("moves the cursor's block down and up, keeping the cursor in it", () => {
    let s = state("First", "Second", "Third");
    s = s.apply(s.tr.setSelection(TextSelection.create(s.doc, 3)));
    s = s.apply(moveBlock(s, 1)!);
    expect(texts(s)).toEqual(["Second", "First", "Third"]);
    expect(s.selection.$from.parent.textContent).toBe("First");
    expect(s.selection.$from.parentOffset).toBe(2);
    s = s.apply(moveBlock(s, -1)!);
    expect(texts(s)).toEqual(["First", "Second", "Third"]);
    expect(moveBlock(s, -1)).toBeNull();
  });

  test("stops at the last block", () => {
    let s = state("A", "B");
    s = s.apply(s.tr.setSelection(TextSelection.create(s.doc, 4)));
    expect(moveBlock(s, 1)).toBeNull();
  });
});

describe("syncSlashMenu", () => {
  test("marks the open menu as a listbox and selects the highlighted entry", () => {
    document.body.innerHTML = `
      <div class="milkdown-slash-menu" data-show="true"><div class="menu-groups">
        <ul><li data-index="0">Text</li><li data-index="1" class="hover">Heading 1</li></ul>
      </div></div><div id="pm"></div>`;
    const menu = document.querySelector(".milkdown-slash-menu")!;
    const editable = document.getElementById("pm")!;
    expect(syncSlashMenu(menu, editable)).toBe("Heading 1");
    expect(menu.querySelector(".menu-groups")!.getAttribute("role")).toBe("listbox");
    expect(menu.querySelector('[data-index="1"]')!.getAttribute("aria-selected")).toBe("true");
    expect(editable.getAttribute("aria-activedescendant")).toBe("dbrief-block-1");
    menu.setAttribute("data-show", "false");
    expect(syncSlashMenu(menu, editable)).toBeNull();
    expect(editable.hasAttribute("aria-activedescendant")).toBe(false);
  });
});

