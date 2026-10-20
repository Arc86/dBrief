import { describe, expect, it } from "vitest";
import { englishStrings, resolveStrings } from "../src/strings";

describe("resolveStrings", () => {
  it("uses English when nothing is injected", () => {
    expect(resolveStrings(undefined)).toEqual(englishStrings);
  });

  it("takes injected strings and keeps English for missing or invalid ones", () => {
    const strings = resolveStrings({ placeholder: "Schrijf de samenvatting", bold: 3, italic: "" });
    expect(strings.placeholder).toBe("Schrijf de samenvatting");
    expect(strings.bold).toBe("Bold");
    expect(strings.italic).toBe("Italic");
  });
});
