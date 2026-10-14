# Babel Echo iOS security

Secrets are stored as generic passwords in Keychain with `AfterFirstUnlockThisDeviceOnly` accessibility. Saving an empty key removes the old item. Settings and meeting JSON contain no key value. Local meeting files use app-private storage and are excluded from backup; files remain accessible after the first unlock so an ongoing recording can survive a locked screen.

The network client accepts HTTPS by default. HTTP requires explicit user opt-in, and redirects are restricted to the configured host. Do not log request headers or audio/transcript content. No endpoint is contacted until the user starts live ASR, explicitly chooses model processing for import, invokes an AI action, explicitly fetches a provider model list, or stops a microphone recording with an available transcript and configured text model (automatic minutes). Screen capture by itself is local-only.

The iOS 27 full-display picker is the authorization boundary for screen capture. Its temporary MP4 may include sensitive screen content; delete it only after WAV conversion succeeds. On failure, keep the recovery file inside app-private, backup-excluded meeting storage. Test this behavior on a physical iOS 27 device before release.

Report security issues privately to the repository owner. Do not commit credentials, recordings, transcripts, provisioning profiles or signing material.

No-auth ASR/text/model-list requests omit any saved API key. Thinking controls are sent only to the exact official `api.deepseek.com` host. Unfinished capture timeouts retain their app-owned temporary MP4 for next-launch recovery rather than moving a file still being finalized. The simulator-only Debug UI-test fixture isolates its meetings/settings and cannot run on physical devices or in Release builds.
