# Publishing an iOS release

This public repository contains the standalone iOS application. Personal development teams are deliberately unset in the Xcode project. Software code is Apache-2.0; the README's brand/artwork notice still applies.

## Prepare

1. Check Git status, app version/build settings and the shared scheme.
2. Run `swift test`, an unsigned simulator build, and appropriate UI tests.
3. Run `./scripts/build-unsigned.sh` with Xcode 27+ for the device-only iOS 27 capture code.
4. Verify the generated IPA has only the intended `Payload/BabelEcho.app`, no provisioning profile, no code-signing identity and no user data. Inspect source and artifact content for secrets, local paths and personal identifiers.
5. Keep certificates, private keys, personal signed IPAs, build logs and device information local.

## Publish

Create an alpha prerelease with a version tag such as `v0.1.0-alpha.3`. Attach the unsigned IPA and `SHA256SUMS.txt` from `dist/`; GitHub also provides source archives for the tag. State the source version, minimum OS, signing requirement, changes, verification and remaining physical-device limits.

The unsigned IPA requires the recipient's own Apple signing and provisioning. It is not an App Store/TestFlight package and is not directly installable. Source installation through Xcode is documented in the README. Personal provisioning expiry dates do not apply to this unsigned artifact; each recipient's signature has its own validity period.

## First standalone snapshot

The first public snapshot uses the latest alpha.3 application sources from the original Babel Echo development workspace. It includes the current shared Xcode scheme. Changes for publication are limited to repository layout, documentation, build tooling and removal of the owner's personal development-team identifiers. The original private history and local install logs are excluded.
