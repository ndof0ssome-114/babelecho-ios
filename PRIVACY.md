# Babel Echo iOS privacy notice

The app stores meeting WAV audio, transcript, summaries, minutes and questions in its private Application Support directory. The meeting directory is excluded from backup. API keys are stored separately in iOS Keychain. There is no account sync or app telemetry.

The app asks for participant recording consent before requesting microphone access. Live transcription is disabled by default. When enabled with an ASR service configured by the user, WAV chunks are sent to that service during recording. Manual transcription sends chunks from a saved recording. Summary, minutes, translation and Q&A send the relevant meeting text to the user's configured text-model endpoint. If a transcript and text model are available, stopping a recording automatically sends the transcript to generate minutes; this is disclosed in the consent prompt and stop control. Provider retention, training, location and cost depend on that provider's terms.

Network requests require HTTPS unless the user explicitly enables HTTP. HTTP does not encrypt audio, text or credentials. Deleting a meeting removes its local JSON and WAV; it cannot remove data already sent to a provider. Export uses the iOS share sheet and creates a temporary copy of the selected document.

The microphone mode records the iPhone microphone. On iOS 27, the separate full-display option uses Apple's screen-sharing picker after an explicit in-app disclosure. During that capture, screen video and system audio are temporarily stored in an app-private MP4. On success, the app extracts a local WAV and deletes the temporary MP4. If conversion fails, the MP4 is preserved in the meeting directory as `screen-recovery.mp4` for recovery. This mode does not automatically upload or transcribe audio. Some apps and protected content may disallow capture; calls and other-app audio are not guaranteed.

Importing an audio/video file is local-only unless the user explicitly selects model processing. Model processing sends extracted audio to the configured ASR endpoint and may send transcript text to the configured text endpoint for minutes. The original file remains where the user selected it.

Fetching a model list is an explicit settings action. It contacts only the selected draft provider's `/models` endpoint, using that provider's draft API key unless no-auth is selected. It sends no meeting text or audio. Copying content writes to the system clipboard only after the user taps Copy all or uses native text selection.
