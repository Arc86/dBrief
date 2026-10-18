import { describe, expect, test } from "vitest";
import { type BridgeMessage, mountEditor, shortcutFor } from "../src/editor";

// Shaped like a real dBrief summary: plain first line, Dutch text with
// diacritics and curly quotes, nested bullets, ordered + task lists, a table.
const realSummary = [
  "Overview",
  "Het UMC Utrecht-team overlegt met ServiceNow (Aaron, Jesper) over de gezondheid van hun ITSM-omgeving.",
  "",
  "## Discussion Points",
  "",
  '* Rutger licht **toe** dat de _change flow_ is aangepast — één voorbeeld: “P&O-groep”.',
  "* Zie [ServiceNow](https://www.servicenow.com) voor details.",
  "  * Genest punt",
  "",
  "1. Health scan draaien",
  "2. Advies opstellen",
  "",
  "* [ ] Jesper stuurt scanresultaten",
  "* [x] Aaron plant sessie",
  "",
  "| Fase | Datum |",
  "| - | - |",
  "| Livegang | Q3 2027 |",
  "",
].join("\n");

async function mount() {
  document.body.innerHTML = '<div id="editor"></div>';
  const messages: BridgeMessage[] = [];
  const api = await mountEditor(document.getElementById("editor")!, (m) => messages.push(m));
  return { api, messages };
}

const words = (s: string) => s.match(/[\p{L}\p{N}]+/gu) ?? [];

describe("mountEditor", () => {
  test("setMarkdown posts the editor's normalized markdown as loaded", async () => {
    const { api, messages } = await mount();
    api.setMarkdown(realSummary);
    expect(messages.filter((m) => m.type === "loaded")).toEqual([
      { type: "loaded", markdown: api.getMarkdown() },
    ]);
  });

  test("round-trip keeps every word of a real summary", async () => {
    const { api } = await mount();
    api.setMarkdown(realSummary);
    expect(words(api.getMarkdown())).toEqual(words(realSummary));
  });

  test("normalization is stable: a second pass changes nothing", async () => {
    const { api } = await mount();
    api.setMarkdown(realSummary);
    const once = api.getMarkdown();
    api.setMarkdown(once);
    expect(api.getMarkdown()).toBe(once);
  });

  test("empty markdown loads as an empty document", async () => {
    const { api, messages } = await mount();
    api.setMarkdown("");
    expect(api.getMarkdown().trim()).toBe("");
    expect(messages.some((m) => m.type === "loaded")).toBe(true);
  });

  test("setTheme writes CSS custom properties on the root element", async () => {
    const { api } = await mount();
    api.setTheme({ "--crepe-color-on-background": "#31405F" });
    expect(document.documentElement.style.getPropertyValue("--crepe-color-on-background")).toBe("#31405F");
  });
});

describe("shortcutFor", () => {
  const key = (init: KeyboardEventInit) => new KeyboardEvent("keydown", { cancelable: true, ...init });

  test("cmd+S saves, Escape cancels", () => {
    expect(shortcutFor(key({ key: "s", metaKey: true }))).toBe("save");
    expect(shortcutFor(key({ key: "Escape" }))).toBe("cancel");
  });

  test("an Escape a menu already handled does not cancel editing", () => {
    // Crepe's slash menu listens on window (capture) and preventDefaults Escape.
    const event = key({ key: "Escape" });
    event.preventDefault();
    expect(shortcutFor(event)).toBeNull();
  });

  test("other keys and modified variants are ignored", () => {
    expect(shortcutFor(key({ key: "s" }))).toBeNull();
    expect(shortcutFor(key({ key: "s", metaKey: true, shiftKey: true }))).toBeNull();
    expect(shortcutFor(key({ key: "Escape", isComposing: true }))).toBeNull();
  });
});
