# Language & Accessibility

dBrief is available in English and Dutch, and works with VoiceOver and the keyboard.

## App language

dBrief follows your Mac's language. If Dutch (Nederlands) is your preferred language in macOS, the whole app is in Dutch: menus, Settings, the viewer, notifications and the summary editor. Otherwise dBrief is in English.

### Use a different language for dBrief only

1. Open **Settings → General**. The **Language** row shows the language dBrief is using.
2. Click **Open Language & Region…**
3. Under **Applications**, click **+**, choose dBrief, and pick a language (for example, Nederlands)
4. Quit and reopen dBrief

### The language of your notes is separate

The app language doesn't change the language of your meeting notes:

- **What was said** is transcribed in the spoken language: see **Settings → Transcription → Language** ([Transcription Overview](../transcription/transcription-overview.md#transcription-language)).
- **Summaries, action items and tags** follow **Settings → AI analysis → Results language → Write results in**: **Same as transcript**, **English**, **Dutch** or **Custom** (a two-letter language code). This card appears for on-device and Local CLI analysis.

So you can use dBrief in English and still get Dutch notes from a Dutch meeting, or the other way round. Exported Markdown and integrations use the language of the notes.

## VoiceOver

VoiceOver announces what happens, so you don't have to look:

- Recording starting, pausing and stopping
- Processing results, and errors
- Search matches in a transcript, saves and copies
- Answers in [Ask dBrief AI](../ai-analysis/transcript-chat.md)
- Progress in the speaker review ("Who's speaking?")

Other help for VoiceOver users:

- **Speaker names without the mouse.** On each transcript turn, the VoiceOver actions menu (VO-Command-Space) offers **Rename "*name*"…**, rename to a known name, **Move this turn to** another speaker, and **This is me** / **Clear "This is me"**. The **Recording** menu also has **Rename Speaker…** and **This Is Me** for the current speaker.
- **The summary has real headings**, so you can move through it with the VoiceOver rotor.
- **The summary editor** is a labelled text box, and its `/` menu is spoken as you move through it. Press **⌥⇧↑** or **⌥⇧↓** to move the current block up or down.
- **Call prompts** stay on screen while VoiceOver is running, instead of dismissing themselves after the time set in **Settings → Meetings**.
- **Call prompts and the floating recording controls** can take keyboard focus when VoiceOver or Full Keyboard Access is on.

## Keyboard

You can run dBrief from the keyboard:

- **Recording:** **⌥⌘P** pauses or resumes and **⌥⌘.** stops, from the menu bar panel, the floating recording controls and the **Recording** menu. In the panel, **⌘R** starts recording.
- **Call prompts** can be reached from the keyboard: **Return** chooses the main button (**Record call**, or **Stop** when a call ended) and **Esc** dismisses.
- **After recording,** **Return** processes the recording on the review screen.
- **In the library,** **↑**/**↓** move through recordings, **Space** plays and pauses, and **⌘1**–**⌘4** switch tabs.
- **Speaker review:** type to search, **↑**/**↓** and **Return** to assign a name, **⌘↑**/**⌘↓** for the previous or next voice, **⌥Space** to play a sample.
- **Voice library:** **Shift-↑/↓** extends the selection, **Return** renames, **⇧⌘M** merges, **Delete** forgets.

See [Keyboard Shortcuts](keyboard-shortcuts.md) for the full list.

## Seeing focus and scroll bars

- Text fields show a clear focus border when you tab into them.
- If **System Settings → Appearance → Show scroll bars** is set to **Always**, dBrief shows permanent scroll bars too. Otherwise its scroll bars appear only while you scroll.
- With **Reduce motion** on in macOS, the [Focus Reader](../history/focus-reader.md)'s controls appear and hide without animating.

## Easier reading

dBrief includes easy-to-read fonts such as Lexend and OpenDyslexic, lets you use any installed font, and lets you set the text size for the app, the viewer and the Focus Reader separately. See [Appearance & Fonts](appearance.md).
