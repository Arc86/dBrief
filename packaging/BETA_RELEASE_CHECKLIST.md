# dBrief Beta Release Checklist

Use this checklist before handing a development build to testers. The supported
completion artifact is `dBrief-Beta.app`; do not create or distribute
`dBrief.app` as part of routine development.

## Automated preflight

- [ ] `git diff --check` passes.
- [ ] `swift test` passes.
- [ ] `make beta` produces `dBrief-Beta.app`.
- [ ] The bundle identifier is `com.dbrief.app.beta`.
- [ ] `SUFeedURL` is absent from the beta `Info.plist`.
- [ ] `codesign --verify --deep --strict dBrief-Beta.app` passes.
- [ ] No production `dBrief.app` artifact remains in the repository root.

Pull requests run the same test, packaging, bundle-identity, update-feed, and
signature checks in `.github/workflows/ci.yml`. CI uses ad-hoc signing because
the local beta identity is intentionally machine-specific.

## Manual smoke test

- [ ] Launch `dBrief-Beta.app` and confirm it uses beta settings/data rather than production data.
- [ ] Confirm microphone and Screen Recording statuses are correct in Settings.
- [ ] Record both microphone and system audio for at least 30 seconds.
- [ ] Pause, wait, resume, and confirm the timer and waveform continue correctly.
- [ ] Stop and save; confirm the recording appears once in history and plays back.
- [ ] Process a recording and confirm transcript, speakers, summary, and action items render.
- [ ] Cancel one processing run, retry it, and confirm the UI returns to a stable state.
- [ ] Queue a recording and confirm it can be processed from the queue.
- [ ] Exercise the configured local/remote engines without exposing meeting content in Console logs.
- [ ] Open About and confirm the beta does not offer the production Sparkle update feed.
- [ ] Quit while idle and relaunch once to catch startup/shutdown regressions.

## Handoff

- [ ] Record the commit SHA, macOS version, and tested transcription/AI engines.
- [ ] Note any skipped smoke-test item and why.
- [ ] Deliver `dBrief-Beta.app` (or the CI-produced `dBrief-Beta.zip`) only.
