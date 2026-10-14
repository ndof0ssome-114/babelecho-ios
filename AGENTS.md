# Babel Echo iOS contributor instructions

- Read `README_AI.md`, `PRIVACY.md` and `SECURITY.md` before implementation changes.
- This is an independent iOS repository. Paths and commands start at this root.
- Preserve local-first storage, explicit recording consent, user-selected providers and HTTPS by default. Keep API keys in Keychain.
- Never commit keys, provisioning profiles, certificates, device IDs, personal team settings, recordings, meeting text, local settings, build logs or packaged binaries.
- Public release artifacts must be unsigned and contain no personal signing identity or provisioning profile. Binary attachments belong in GitHub Releases, not Git history.
- Do not import the private monorepo's Git history. This repository starts with a reviewed iOS-only source snapshot.
- Keep saved meeting/settings decoding backward compatible; preserve audio on network or conversion failures.
- Inspect Git status before editing and preserve unrelated work. Use focused commits.
- Run `swift test` and an unsigned Xcode build for relevant changes; inspect the UI for UI changes. Run `git diff --check` before committing.
- Synthetic tests and simulator builds do not verify physical microphone/system audio, background behavior or real cloud providers. Report the actual verification and remaining limits.
- Keep `README_AI.md` current when architecture, data handling, workflow or known limitations change.
