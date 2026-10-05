import { afterEach, describe, expect, test } from "vitest";
import { contentHeight, floatingMargin, isFloatingVisible, measureHeight } from "../src/height";

describe("contentHeight", () => {
  test("a plain document reports the editor's bottom, rounded up, with no margin", () => {
    expect(contentHeight(240.2, [])).toBe(241);
  });

  test("a visible menu below the document extends the height by the margin", () => {
    expect(contentHeight(200, [{ bottom: 420.5, visible: true }], 12)).toBe(433);
  });

  test("hidden menus are ignored even when they sit lower", () => {
    expect(contentHeight(200, [{ bottom: 900, visible: false }], 12)).toBe(200);
  });

  test("a visible menu inside the document does not grow it", () => {
    expect(contentHeight(300, [{ bottom: 120, visible: true }], 12)).toBe(300);
  });

  test("the lowest visible menu wins", () => {
    const boxes = [
      { bottom: 260, visible: true },
      { bottom: 510, visible: false },
      { bottom: 380, visible: true },
    ];
    expect(contentHeight(200, boxes, 10)).toBe(390);
  });
});

describe("isFloatingVisible", () => {
  const element = (show?: string) => {
    const el = document.createElement("div");
    if (show !== undefined) el.setAttribute("data-show", show);
    return el;
  };
  const box = { width: 200, height: 120 };

  test("data-show=false hides, true or absent shows", () => {
    expect(isFloatingVisible(element("false"), box)).toBe(false);
    expect(isFloatingVisible(element("true"), box)).toBe(true);
    expect(isFloatingVisible(element(), box)).toBe(true);
  });

  test("an element without a rendered box is not visible", () => {
    expect(isFloatingVisible(element("true"), { width: 0, height: 0 })).toBe(false);
  });
});

describe("measureHeight", () => {
  afterEach(() => {
    document.body.innerHTML = "";
  });

  const rect = (top: number, height: number, width = 100) =>
    ({ top, bottom: top + height, height, width, left: 0, right: width, x: 0, y: top, toJSON() {} }) as DOMRect;

  const stub = (el: Element, r: DOMRect) => {
    el.getBoundingClientRect = () => r;
  };

  function setup() {
    document.body.innerHTML = `
      <div id="editor"><div class="milkdown">
        <div class="ProseMirror"></div>
        <div class="milkdown-slash-menu" data-show="false"></div>
        <div class="milkdown-toolbar" data-show="false"></div>
        <div class="milkdown-link-edit" data-show="false"></div>
      </div></div>`;
    const root = document.getElementById("editor")!;
    stub(root, rect(0, 180));
    const slash = root.querySelector(".milkdown-slash-menu")!;
    const toolbar = root.querySelector(".milkdown-toolbar")!;
    const linkEdit = root.querySelector(".milkdown-link-edit")!;
    stub(slash, rect(150, 300));
    stub(toolbar, rect(20, 40));
    stub(linkEdit, rect(170, 40));
    return { root, slash, toolbar, linkEdit };
  }

  test("only the editor counts while every menu is hidden", () => {
    const { root } = setup();
    expect(measureHeight(root)).toBe(180);
  });

  test("an open slash menu below the last line grows the height", () => {
    const { root, slash } = setup();
    slash.setAttribute("data-show", "true");
    expect(measureHeight(root)).toBe(450 + floatingMargin);
  });

  test("a link editor just under the document grows it; an inner toolbar does not", () => {
    const { root, toolbar, linkEdit } = setup();
    toolbar.setAttribute("data-show", "true");
    expect(measureHeight(root)).toBe(180);
    linkEdit.setAttribute("data-show", "true");
    expect(measureHeight(root)).toBe(210 + floatingMargin);
  });

  test("measures in document coordinates when the page is scrolled", () => {
    const { root } = setup();
    expect(measureHeight(root, 25)).toBe(205);
  });
});
