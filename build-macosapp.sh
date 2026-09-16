#!/usr/bin/env bash
#
# build-macosapp.sh — build the Mac app, Release, universal (arm64 + x86_64).
#
# The counterpart to package.sh, which does the same job for the sideloaded iOS
# IPA. Three things that script does are deliberately absent here:
#
#   * SIDELOAD. That condition switches on the silent keep-alive audio, which
#     exists to stop iOS suspending a Remote Controllable phone with the screen
#     off — and is the thing App Store guideline 2.5.4 forbids (see
#     StayAwake.swift). macOS does not suspend a running app, so the Mac build
#     has nothing to switch on and ships the same code either way.
#   * The pngquant pass. That lowers the 1024² icon's colour entropy because the
#     compiled asset catalog is a real slice of a ~10 MB IPA. A .app you drag to
#     /Applications is not fighting for those 350 KB, and the Mac icon set is
#     seven separate files rather than the one slot.
#   * Stripping the binary. package.sh can strip because the IPA is unsigned and
#     AltStore re-signs it on install; here the bundle is already signed when the
#     build ends, and stripping it afterwards would invalidate that.
#
# Signing: the target asks for automatic signing with no team set, so the result
# is AD-HOC signed with the hardened runtime on. That launches fine on any Mac
# you copy it to by hand, but it is NOT notarized — a Mac that downloads the zip
# through a browser will quarantine it, and the first launch needs
# right-click → Open (or `xattr -d com.apple.quarantine`).
#
# Usage: ./build-macosapp.sh [--clean]
#
#   --clean   full rebuild. Off by default: the vendored C++ (the restoration
#             DSP and the BPM analysis core) is most of the compile and does not
#             change between runs, so an incremental build is the one worth
#             having while iterating on the app.
#
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
APP_NAME="Pocket Tandas.app"
ZIP_NAME="Pocket Tandas-macOS.zip"

ACTIONS=(build)
if [ "${1:-}" = "--clean" ]; then
  ACTIONS=(clean build)
elif [ -n "${1:-}" ]; then
  echo "usage: $(basename "$0") [--clean]" >&2
  exit 2
fi

# Shares the `build/` derived-data path with package.sh; the two land in
# different product directories (Release vs Release-iphoneos) and never collide.
xcodebuild \
  -project "Pocket Tandas.xcodeproj" \
  -scheme "Pocket Tandas macOS" \
  -configuration Release \
  -derivedDataPath build \
  ENABLE_CODE_COVERAGE=NO \
  "${ACTIONS[@]}"

BUILT="build/Build/Products/Release/$APP_NAME"
[ -d "$BUILT" ] || { echo "==> expected $BUILT, which the build did not produce" >&2; exit 1; }

rm -rf "${ROOT:?}/$APP_NAME"
cp -R "$BUILT" "$ROOT/"

# ditto rather than zip: it is the archiver that preserves the bundle's symlinks
# and its code signature. A plain `zip -r` flattens both, and what comes out the
# other end fails Gatekeeper for reasons that have nothing to do with the build.
rm -f "${ROOT:?}/$ZIP_NAME"
ditto -c -k --keepParent "$ROOT/$APP_NAME" "$ROOT/$ZIP_NAME"

codesign --verify --strict "$ROOT/$APP_NAME"

echo
echo "==> $APP_NAME   $(lipo -archs "$ROOT/$APP_NAME/Contents/MacOS/Pocket Tandas")"
echo "==> $ZIP_NAME   $(ls -l "$ROOT/$ZIP_NAME" | awk '{print $5}') bytes"
