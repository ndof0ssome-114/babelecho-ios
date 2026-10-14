# Babel Echo iOS implementation guide

Version: `0.1.0-alpha.3`. Deployment target: iOS 17. No third-party packages.

Read `AGENTS.md` and this guide first. This repository contains only the iOS application. `PRIVACY.md` and `SECURITY.md` define data handling.

## Architecture

- `BabelEchoApp.swift`: SwiftUI entry point.
- `ContentView.swift`: workspace, history, settings, recording consent, playback and export UI. Interface copy is selected in Chinese, Japanese or English.
- `AppModel.swift`: UI state, recording lifecycle, serial ASR queue, transcript persistence and AI actions.
- `AudioRecorder.swift`: `AVAudioEngine` microphone tap, mono mixdown, 16 kHz resampling, WAV streaming, metering, voice-activity finalization and interim utterances. `WAVWriter.swift` holds the reusable PCM writer.
- `DisplayCapture.swift`: iOS 27 physical-device-only ScreenCaptureKit system picker and temporary MP4 recording; not compiled into the simulator binary because its SDK lacks ScreenCaptureKit. Full-display capture needs `screen-capture` background mode. No capture starts without the user selecting content in the system picker.
- `MediaImporter.swift`: AVFoundation streaming decode of an audio track from audio/video media to 16 kHz mono WAV; source files chosen through the Files picker use security-scoped access.
- `CloudClient.swift`: user-configured MiMo, Groq/OpenAI-compatible and Deepgram ASR; Deepgram diarized utterances; task-specific text model routing. Checks HTTPS unless HTTP was explicitly enabled. Redirects remain on the original host. No request is sent until the user enables an action.
- `MeetingStore.swift`: one `meeting.json` and `recording.wav` per meeting under Application Support. JSON writes are atomic and the meeting directory is excluded from backup.
- `Models.swift`: versioned meeting and settings schema with optional new fields for old JSON compatibility; API keys are separate generic-password Keychain items, accessible after first unlock on this device. Provider keys use `asr.<id>` / `llm.<id>` accounts.

## Recording workflow

The user confirms participant consent, then the app requests microphone permission. `AVAudioSession` uses `.playAndRecord` with `.measurement`; the project declares audio background mode. The recorder writes PCM to the local WAV as it arrives. Paused audio is not written. An interruption stops and closes the WAV. The microphone path does not promise internal audio from another app. A start reservation is taken before the asynchronous microphone-permission request, so repeated taps cannot start duplicate engines or meetings. Startup failure closes the WAV and deactivates the audio session, including invalid input-format failures.

Live transcription is off by default. When on and ASR is configured, voice activity opens an utterance, sends a provisional request every three seconds, and finalizes after approximately 1.2 seconds of silence. The 30-second maximum uses a 1.2-second overlap. At most six final chunks wait in the serial ASR queue; if ASR falls behind, local audio remains intact for manual retranscription. Failed ASR/LLM requests do not delete the local WAV. Manual retranscription only replaces the saved transcript after every chunk succeeds, preserving old text on failure.

Media import is local-only by default. The user can explicitly opt into ASR and minutes generation before importing. Audio/video input is decoded into a protected WAV under the meeting directory. A failed import preserves the original external file. On iOS 27, screen capture temporarily records an MP4 in the app sandbox and converts it on stop; the temporary MP4 is removed only after WAV conversion succeeds, otherwise retained in the meeting directory as `screen-recovery.mp4`. An interrupted capture's app-owned temp MP4 is moved into a recoverable meeting on next launch. The UI offers retry and export for recovery files. Screen capture does not automatically upload or transcribe audio. This mode currently records system audio only, not a microphone/system mix. System-audio capture, local save and WAV playback were confirmed by the user on a physical iPhone on 2026-10-03. Background, lock-screen and interruption behavior still require verification.

Automatic summary sends the previous summary plus segments added since `summaryUpTo`. Manual and automatic summaries cannot run concurrently for the same meeting; both commit only the captured segment count, so text arriving during a request stays eligible for the next summary. A manual full summary and long-form minutes use hierarchical chunks for long transcripts. Structured minutes request decisions, actions, risks, questions and chapters; if a provider does not return valid JSON, the original model text is preserved. Translation uses segment UUIDs, and Q&A includes only the latest four prior pairs. Deepgram utterances carry speakers; other ASR uses a lightweight heuristic and the user can rename or ask a text model to resplit speakers. Meeting JSON stores text, timestamps, summary cursor, structured minutes, questions and call counts. Exports include MD, TXT, VTT, bilingual VTT and JSON. No account sync or telemetry exists.

When recording stops, a configured text model automatically creates minutes only if transcript segments exist. The consent text and stop control disclose this transmission. Without a configured text model or transcript, stopping is local-only.

## Invariants and next verification

- Never silently delete or replace a recording after a model error.
- Do not place API keys in `AppSettings` or meeting JSON.
- Maintain HTTPS validation at the network boundary even if the UI warns about HTTP.
- Schema changes require defaulted decoding or explicit migration and a fixture for an older meeting.
- Record the exact Xcode build and device test results. A build does not verify microphone quality or background behavior.
- Test real ASR/LLM compatibility with the selected provider; OpenAI-compatible endpoints vary.
- iOS app icon was derived from the original Babel Echo brand master; release artwork must be checked for Apple's icon alpha and safe-area requirements.

Unlike desktop, iOS 17–26 cannot use this ScreenCaptureKit path; the iOS 27 capture mode has user-confirmed foreground system-audio recording/save/playback and may be limited by protected content or other apps. Desktop tray/keyboard shortcuts have no direct iPhone equivalent. The statistics panel tracks successful ASR request time (including provisional requests), estimated ASR cost from user-editable rates, and model-reported text tokens by task. These estimates are not a bill: failed requests and providers without token data may be undercounted, and old meetings cannot be reconstructed. Provider protocol behavior must be verified against real configured accounts before claiming full compatibility. Run `swift test` for old-meeting decoding, routing and AAC import, plus unsigned simulator/device-target Xcode builds. Dark and light workspace appearance were visually inspected in the iOS 26.5 simulator and on a physical iOS 27 iPhone.

2026-09-28 physical iPhone check: the signed alpha.2 app installed as an update and preserved earlier meetings. In light and dark system appearance, workspace headings, cards and tabs remained readable. Two local microphone test WAVs were saved (about 20 and 14 seconds), and the shorter recording showed its finalized duration and entered playback immediately after stopping. The files were confirmed as 16 kHz mono PCM. iPhone Mirroring blocks use of the iPhone microphone, so these tests verify persistence and playback state, not microphone signal quality or speech recognition. The history list retained all five meetings. The system ScreenCaptureKit picker could not be completed through iPhone Mirroring, so screen-audio capture and background behavior are still unverified. No external ASR or text provider was configured for the device test; no audio was uploaded.

Physical-device check before declaring parity: install an update preserving the earlier meeting, switch light/dark appearance and inspect text contrast, make a short microphone recording with pause/resume, import an audio and a video file, check WAV playback/timestamp seeking and exports, then authorize full-display capture on iOS 27 and verify system audio survives backgrounding. Repeat screen capture with an interrupted stop to exercise retry/export. Finally, use an intentionally harmless test utterance for each configured ASR/text provider and compare transcripts, diarization, token statistics and provider-side usage. The user should not need to disclose real meeting content or API keys in chat.

## Alpha.3 changes and verification (2026-10-03)

- Transcript/translation and Q&A text support native selection. A Copy all control copies the current transcript (including speaker names and translations), summary, minutes or Q&A only after a user tap. Content tabs have distinct accessibility names and scroll horizontally for large text. Recording controls stack at accessibility text sizes; history rows use standard primary/secondary contrast. Settings have a top Save button and retain unsaved drafts across tab changes.
- Task model editors support explicit `/models` discovery at the draft provider endpoint with its draft key; discovery never runs automatically and never overwrites a manually typed model ID. Changing provider resets model/thinking choices; provider/URL/auth changes invalidate late list responses. Official `api.deepseek.com` endpoints alone receive optional `thinking.type`; fresh summary/translation defaults disable thinking. Old saved roles preserve provider defaults through an optional field.
- Text output is bounded (4,096 tokens normally, 8,192 for minutes, 16,384 when official DeepSeek thinking/default mode is used). Empty or truncated content does not overwrite existing documents and is not automatically retried. Reported usage is captured before content validation, with optional reasoning tokens stored as a subset of completion tokens. `llmCalls` counts completed logical actions; per-task usage counts individual returned requests. HTTP/network failures may still lack provider usage. No-auth requests omit saved keys. Credentials and transport injection exist for offline tests, with Keychain/ephemeral URLSession as production defaults.
- ScreenCaptureKit lifecycle runs on MainActor, ignores duplicate or out-of-order callbacks, supports cancellation during startup and uses 30-second startup/stop deadlines. AppModel additionally guards callbacks with a session UUID. Finalized failed MP4s remain recoverable; a timeout never moves a file still owned by the output, leaving it for next-launch recovery. A busy model operation preserves a completed capture as a recoverable meeting instead of leaving an unlisted temp file. Microphone controls remain hidden in this capture mode.
- WAVWriter now seeks beyond the 44-byte header before writing PCM, preventing finalization from overwriting the initial 22 samples. Closing is idempotent and release finalizes the header. Retrying media extraction atomically replaces an earlier WAV only after successful decoding; failed decoding preserves the existing file.
- Core tests: 16 XCTest checks passed, including old meeting/settings fields, lifecycle ordering/cancellation, scoped credentials/no-auth, thinking/output bounds, model discovery/unsafe URLs, incomplete-response usage, exact WAV payload, AAC conversion, retry replacement and failed-import preservation. All network responses and audio are synthetic; no real microphone or cloud provider was used for these tests.
- Xcode 27.0 (`27A266a`): unsigned simulator and device builds plus signed physical-device build passed. The alpha.3 app was installed as an update on the connected iPhone. File paths and sizes for all six earlier meetings remained unchanged. After user testing, a new local screen WAV appeared; the user explicitly confirmed it plays the video sound. This is user-reported signal verification, not an automated measurement. No microphone test was performed in this session.
- `BabelEchoUITests` is a shared scheme target. Its `--ui-test-fixture` works only in Debug simulator builds, uses a separate meeting directory and settings suite, and creates silent synthetic WAVs. Dedicated simulator-only flags force actual dark appearance and the maximum accessibility text size; generic UIKit launch defaults did not reliably change the captured appearance in this environment. It is excluded from the physical and Release app. All five UI checks passed on the iOS 27 iPhone 18 Pro simulator. The UI tests check copying, panel switching, provider/model reset, unsaved drafts, recording-consent cancellation, history, dark-mode playback and large-text navigation. Store root injection supports that isolated fixture; ordinary storage paths are unchanged.

Run UI checks with an available simulator:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project BabelEcho.xcodeproj -scheme BabelEcho \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath /private/tmp/babelecho-ios-ui CODE_SIGNING_ALLOWED=NO test
```

Real provider ASR/translation/minutes, microphone signal quality, locked/background recording, DRM/unsupported content and capture failure recovery are still unverified in alpha.3. Use deliberate harmless content and the user's chosen providers for those checks.


## Standalone public repository (2026-10-14)

This snapshot starts an independent iOS history at alpha.3. The original app code and test fixtures are unchanged. Personal development-team IDs were removed, and build/test paths now refer to this repository root. Never import the private monorepo history. Public releases contain a fresh unsigned Release IPA and a SHA-256 checksum; no personal provisioning profiles, signed developer packages, certificates, device identifiers, signing keys or local build logs are published. Choose your own signing team and bundle ID in Xcode for installation. The publishing workflow is documented in `docs/RELEASING.md`.
