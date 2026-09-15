# Dutch SpeechTranscriber asset unavailable

Observed on 2026-09-13, macOS 26.6.2 (25G83), Apple silicon M3 Air.

## Reproduction independent of dBrief

The diagnostic uses only public Speech APIs. It does not open, record, or transmit audio.
Run outside an agent/tool sandbox: a sandboxed probe falsely returned no supported locales, including English.

```sh
swiftc -parse-as-library scripts/AppleSpeechAssetProbe.swift -o /tmp/dbrief-speech-probe
/tmp/dbrief-speech-probe
/tmp/dbrief-speech-probe --install
```

The optional `--install` requests Apple's Dutch language model download. `--reserve` additionally reserves the locale explicitly; reservations otherwise happen automatically as part of the installation request.

Observed results:

- `SpeechTranscriber.isAvailable`: true.
- `SpeechTranscriber.installedLocales`: nine English locales; no Dutch locales.
- `supportedLocale(equivalentTo: nl)`: `nl_NL`.
- `supportedLocale(equivalentTo: nl-NL)`: `nl_NL`.
- `supportedLocale(equivalentTo: nl-BE)`: `nl_BE`.
- `AssetInventory.status(forModules:)`: `unsupported` for Dutch; `supported` for English in the standalone probe's identity.
- `downloadAndInstall()` throws `SFSpeechErrorDomain`, code 1: `transcription.nl asset unavailable after attempted download, final state: Not Installing`.
- Explicit reservation and a second installation attempt produce the same error.
- 55 GiB free space at time of reproduction.

The probe's identity differs from dBrief's. Reproducing the identical installation error establishes that dBrief's transcription pipeline is not required to trigger it. It does not identify whether the underlying failure is Apple's asset catalog, distribution service, or local asset service state.

## Expected behavior

A locale advertised by `SpeechTranscriber.supportedLocale` should either have installable assets, or be reported as unavailable consistently. English macOS should not require switching the UI language to transcribe a supported Dutch locale.

## App behavior

dBrief previously trusted locale resolution, attempted one installation, and showed the raw system failure. Both live and recorded transcription used this pattern. The installation API already reserves locales automatically, so a missing explicit `reserve` call is not the demonstrated cause.

Asset preparation now checks the inventory, skips downloads for unavailable assets, verifies installation before recognition, and retries a recoverable initial failure once. Failures include resolved locale, final asset state, OS version, and the original error domain/code in diagnostic logging. Cancellation remains cancellation. No automatic engine/language switch or cloud fallback is added for asset failures.

This improves app behavior; it does not make Apple's unavailable Dutch asset downloadable. End-to-end Dutch transcription must be revalidated once Apple reports the asset as available and installation succeeds.

## Apple references

- https://developer.apple.com/documentation/speech/assetinventory
- https://developer.apple.com/documentation/speech/assetinventory/assetinstallationrequest(supporting:)
- https://developer.apple.com/forums/thread/797835

In the forum thread Apple says a failed initial attempt can be retried without duplicate downloads. Apple later confirmed that a similar Arabic case was an incorrectly advertised supported locale. This is supporting context, not proof that Dutch has the same underlying defect.

## Feedback report

Title: macOS 26.6.2 SpeechTranscriber advertises Dutch but transcription.nl asset is unsupported and cannot install

Attach this reproduction, the diagnostic source and its output to an Apple Feedback report. Include a sysdiagnose if Apple requests one. No report has been submitted automatically.
