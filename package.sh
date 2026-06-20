#!/usr/bin/env bash
#
# package.sh — build an unsigned Release IPA, optimized for size.
#
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
ICON="$ROOT/Pocket Tandas/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

# --- Optional: shrink the app icon before the asset catalog is compiled. ---
# actool decodes every catalog image to a raw ARGB bitmap and re-compresses it
# with lzfse inside Assets.car, so the source file's *format* (PNG/WebP/HEIC) and
# any *lossless* optimizer make no difference to the shipped size — only the
# icon's colour entropy does. pngquant (lossy palette reduction) lowers that
# entropy and roughly halves the icon's footprint in the .car (~350 KB off the
# IPA). We quantize a throwaway copy and always restore the pristine source
# afterwards (explicitly, and via an EXIT trap), so the committed icon is never
# degraded. Skipped automatically when pngquant isn't installed.
ICON_BAK=""
restore_icon() {
  if [ -n "$ICON_BAK" ] && [ -f "$ICON_BAK" ]; then mv -f "$ICON_BAK" "$ICON"; fi
  ICON_BAK=""
}
trap restore_icon EXIT

if command -v pngquant >/dev/null 2>&1; then
  echo "==> pngquant: shrinking app icon for this build"
  ICON_BAK="$(mktemp)"
  cp "$ICON" "$ICON_BAK"
  pngquant --force --strip --output "$ICON" -- "$ICON_BAK" \
    || { echo "    (pngquant couldn't hit quality — shipping full-colour icon)"; cp "$ICON_BAK" "$ICON"; }
else
  echo "==> pngquant not installed — full-colour icon (brew install pngquant to shave ~350 KB)"
fi

xcodebuild \
  -project "Pocket Tandas.xcodeproj" \
  -scheme "Pocket Tandas" \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_CODE_COVERAGE=NO \
  clean build

restore_icon   # actool has consumed the icon; put the pristine source back now


cd build/Build/Products/Release-iphoneos

rm -rf Payload && mkdir Payload
cp -R "Pocket Tandas.app" Payload/

# Strip the symbol table from the shipped binary. A plain `xcodebuild build`
# (as opposed to archive/install) leaves DEPLOYMENT_POSTPROCESSING=NO, so the
# ~2 MB debug symbol table is never removed despite STRIP_INSTALLED_PRODUCT=YES.
# The IPA is unsigned (AltStore re-signs on install), so stripping here is safe;
# we only lose crash symbolication, which sideloaded builds don't use anyway.
strip "Payload/Pocket Tandas.app/Pocket Tandas"

zip -9 -qr "Pocket Tandas.ipa" Payload
mv -f "Pocket Tandas.ipa" "$ROOT/"


cd "$ROOT"
echo "==> Built Pocket Tandas.ipa ($(ls -l "Pocket Tandas.ipa" | awk '{print $5}') bytes)"
