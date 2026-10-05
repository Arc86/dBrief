# dBrief summary block editor

Milkdown Crepe, tree-shaken and bundled for the Summary card's inline editor
(`MarkdownBlockEditor` / `MarkdownEditorController` in the app).

The build output in `Sources/dBrief/Resources/MarkdownEditor/` is **committed** so
`make app` needs no Node. After changing anything here or bumping `@milkdown/*`:

    npm ci
    npm test
    npm run build

then commit the regenerated `Sources/dBrief/Resources/MarkdownEditor/` files.
