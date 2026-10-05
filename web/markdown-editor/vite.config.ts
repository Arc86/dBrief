import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

// Builds one classic (IIFE) script + one stylesheet straight into the app's
// Resources so `make app` never needs Node. public/index.html is copied as-is.
export default defineConfig({
  base: "./",
  test: { environment: "jsdom" },
  build: {
    outDir: fileURLToPath(new URL("../../Sources/dBrief/Resources/MarkdownEditor", import.meta.url)),
    emptyOutDir: true,
    cssCodeSplit: false,
    modulePreload: false,
    rollupOptions: {
      input: "src/main.ts",
      output: {
        format: "iife",
        entryFileNames: "editor.js",
        assetFileNames: "editor[extname]",
      },
    },
  },
});
