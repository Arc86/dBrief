import { afterEach, describe, expect, test } from "vitest";
import { animateReorder, displacements, snapshotBlocks } from "../src/reorder";

/** jsdom has no layout: give each block a fixed top that follows its DOM order. */
function layout(container: HTMLElement, rowHeight = 40) {
  Array.from(container.children).forEach((element, index) => {
    (element as HTMLElement).getBoundingClientRect = () =>
      ({ top: index * rowHeight, bottom: (index + 1) * rowHeight, left: 0, right: 0, width: 0, height: rowHeight }) as DOMRect;
  });
}

function blocks(...names: string[]) {
  document.body.innerHTML = `<div id="pm">${names.map((n) => `<p id="${n}">${n}</p>`).join("")}</div>`;
  const container = document.getElementById("pm")!;
  layout(container);
  return container;
}

afterEach(() => {
  document.body.innerHTML = "";
});

describe("displacements", () => {
  test("blocks that shifted report how far they moved, so they can glide from the old spot", () => {
    const container = blocks("a", "b", "c");
    const before = snapshotBlocks(container);
    container.append(document.getElementById("a")!); // drag "a" to the end
    layout(container);

    const { moved, arrived } = displacements(before, container);
    expect(moved.map((m) => [m.element.id, m.dy])).toEqual([
      ["b", 40],
      ["c", 40],
      ["a", -80],
    ]);
    expect(arrived).toEqual([]);
  });

  test("ProseMirror re-creating the dropped block shows up as an arrival, not a move", () => {
    const container = blocks("a", "b", "c");
    const before = snapshotBlocks(container);
    document.getElementById("a")!.remove();
    const fresh = document.createElement("p");
    fresh.id = "a2";
    container.append(fresh);
    layout(container);

    const { moved, arrived } = displacements(before, container);
    expect(moved.map((m) => [m.element.id, m.dy])).toEqual([
      ["b", 40],
      ["c", 40],
    ]);
    expect(arrived.map((e) => e.id)).toEqual(["a2"]);
  });

  test("sub-pixel jitter is not a move", () => {
    const container = blocks("a", "b");
    const before = snapshotBlocks(container);
    (document.getElementById("b") as HTMLElement).getBoundingClientRect = () => ({ top: 40.4 }) as DOMRect;
    expect(displacements(before, container).moved).toEqual([]);
  });
});

describe("animateReorder", () => {
  test("starts each moved block at its old position and marks arrivals", () => {
    const container = blocks("a", "b");
    const b = document.getElementById("b") as HTMLElement;
    const fresh = document.getElementById("a") as HTMLElement;

    animateReorder({ moved: [{ element: b, dy: 40 }], arrived: [fresh] });
    expect(b.style.transform).toBe("translateY(40px)");
    expect(fresh.classList.contains("dbrief-dropped")).toBe(true);
  });

  test("reduced motion skips the glide but still marks the dropped block", () => {
    const container = blocks("a", "b");
    const b = document.getElementById("b") as HTMLElement;
    const fresh = document.getElementById("a") as HTMLElement;

    animateReorder({ moved: [{ element: b, dy: 40 }], arrived: [fresh] }, { reduceMotion: true });
    expect(b.style.transform).toBe("");
    expect(fresh.classList.contains("dbrief-dropped")).toBe(true);
    expect(container.children.length).toBe(2);
  });
});
