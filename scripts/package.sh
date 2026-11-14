#!/bin/bash
# Builds SSClip.app for Apple silicon and packages it as a DMG and a ZIP; the in-app updater
# installs the ZIP from the GitHub release.
#   VERSION, BUILD_NUMBER   written into Info.plist (default: the version in Resources/Info.plist / 1)
#   SIGN_IDENTITY           codesign identity (default "-", ad-hoc)
#   SIGN_KEYCHAIN           keychain holding the identity (optional)
#   WORK_DIR                intermediates (default ./.build)
#   DIST_DIR                where the DMG and ZIP go (default ./dist)
set -euo pipefail
cd "$(dirname "$0")/.."

version="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
build_number="${BUILD_NUMBER:-1}"
identity="${SIGN_IDENTITY:--}"
work="${WORK_DIR:-$PWD/.build}"
dist="${DIST_DIR:-$PWD/dist}"
stage="$work/stage-$build_number"
app="$stage/SSClip.app"

[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "VERSION must look like 1.0.3, got $version" >&2; exit 1; }
[ -s Resources/AppIcon.icns ] || { echo "Missing Resources/AppIcon.icns" >&2; exit 1; }

swift build -c release --arch arm64 --scratch-path "$work/spm"
bin="$(swift build -c release --arch arm64 --scratch-path "$work/spm" --show-bin-path)/SSClip"

if [ -e "$stage" ]; then
  echo "$stage already exists; use a new BUILD_NUMBER or a clean WORK_DIR" >&2
  exit 1
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$dist"
cp "$bin" "$app/Contents/MacOS/SSClip"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" \
  -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"

sign=(codesign --force --sign "$identity" --timestamp=none)
[ -z "${SIGN_KEYCHAIN:-}" ] || sign+=(--keychain "$SIGN_KEYCHAIN")
"${sign[@]}" "$app"
codesign --verify --strict --verbose=2 "$app"
codesign -dvv "$app" 2>&1 | grep -E '^(Identifier|Authority|Signature)' || true
lipo -archs "$app/Contents/MacOS/SSClip" | grep -qw arm64 || { echo "SSClip is not built for arm64" >&2; exit 1; }

name="SSClip-$version"
ditto -c -k --sequesterRsrc --keepParent "$app" "$dist/$name.zip"
ln -s /Applications "$stage/Applications"
hdiutil create -volname SSClip -srcfolder "$stage" -ov -format UDZO "$dist/$name.dmg"
[ "$identity" = "-" ] || "${sign[@]}" "$dist/$name.dmg"
(cd "$dist" && shasum -a 256 "$name.zip" "$name.dmg" | tee "$name.sha256")
