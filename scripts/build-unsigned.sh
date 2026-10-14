#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${BABEL_ECHO_BUILD_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/babelecho-ios-build.XXXXXX")}"
dist_root="${BABEL_ECHO_DIST_DIR:-$repo_root/dist}"
package_root="$(mktemp -d "${TMPDIR:-/tmp}/babelecho-ios-package.XXXXXX")"
trap 'rm -rf "$package_root"' EXIT

xcodebuild -project "$repo_root/BabelEcho.xcodeproj" -scheme BabelEcho \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$build_root" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM= GCC_GENERATE_DEBUGGING_SYMBOLS=NO \
  SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO DEBUG_INFORMATION_FORMAT= build

app_path="$build_root/Build/Products/Release-iphoneos/BabelEcho.app"
mkdir -p "$package_root/Payload" "$dist_root"
ditto --norsrc --noextattr "$app_path" "$package_root/Payload/BabelEcho.app"
payload_app="$package_root/Payload/BabelEcho.app"
if find "$payload_app" -name '*.mobileprovision' -o -name '*.provisionprofile' | grep -q .; then
  echo 'Refusing to publish an app containing a provisioning profile.' >&2
  exit 1
fi
if codesign --display "$payload_app/BabelEcho" >/dev/null 2>&1; then
  codesign --remove-signature "$payload_app/BabelEcho"
fi
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$payload_app/Info.plist")"
artifact="BabelEcho-${version}-unsigned.ipa"
ditto -c -k --norsrc --keepParent "$package_root/Payload" "$dist_root/$artifact"
(
  cd "$dist_root"
  shasum -a 256 "$artifact" > SHA256SUMS.txt
)
printf 'Unsigned IPA: %s\nChecksums: %s\n' "$dist_root/$artifact" "$dist_root/SHA256SUMS.txt"
