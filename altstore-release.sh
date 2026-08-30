#!/usr/bin/env bash
#
# altstore-release.sh — build an unsigned IPA and refresh the AltStore source.
#
# Runs package.sh to produce an unsigned .ipa, verifies it, then injects this
# build's metadata (version, size, sha256, download URL, date) into apps.json so
# it can be served as an AltStore source. The version entry is prepended and
# de-duplicated, so re-running for the same version replaces in place and older
# versions are kept as history — identical to .github/workflows/release.yml.
#
# It does NOT push a tag, create the GitHub Release, or commit; it prints those
# next steps. Publish the IPA at the printed download URL for the source to work.
#
# Usage:
#   ./altstore-release.sh
#   RELEASE_NOTES="Initial release." ./altstore-release.sh   # set the changelog
#   SKIP_BUILD=1 ./altstore-release.sh                       # reuse the last build
#
set -euo pipefail
cd "$(dirname "$0")"

command -v jq >/dev/null || { echo "error: jq is required — install with: brew install jq" >&2; exit 1; }

APP_NAME="Pocket Tandas"
SOURCE_JSON="apps.json"
ICON_FILE="icon_512.png"
MIN_OS="17.0"
DEVELOPER="Nick Shaforostov"

# Derive owner/repo from the git remote so URLs aren't hardcoded.
SLUG=$(git remote get-url origin | sed -E 's#(git@github\.com:|https://github\.com/)##; s#\.git$##')
RAW_BASE="https://raw.githubusercontent.com/${SLUG}/main"
REL_BASE="https://github.com/${SLUG}/releases/download"

# 1. Build the unsigned IPA (skippable to just refresh apps.json from the last build).
if [ -z "${SKIP_BUILD:-}" ]; then
  echo "==> Building unsigned IPA (package.sh)…"
  bash package.sh
fi

IPA="${APP_NAME}.ipa"   # name produced by package.sh
[ -f "$IPA" ] || { echo "error: ${IPA} not found — run without SKIP_BUILD" >&2; exit 1; }

# 2. Verify the IPA actually contains the app (guards against empty-Payload builds).
#    Capture the listing and glob-match it — piping into `grep -q` can race with
#    SIGPIPE under `set -o pipefail` and fail spuriously.
case "$(unzip -l "$IPA")" in
  *"Payload/${APP_NAME}.app/"*) : ;;
  *) echo "error: ${IPA} has no Payload/${APP_NAME}.app — build failed" >&2; exit 1 ;;
esac
[ "$(stat -f%z "$IPA")" -gt 500000 ] \
  || { echo "error: ${IPA} suspiciously small — build likely failed" >&2; exit 1; }

# 3. Read version + bundle id from the built app.
PLIST="build/Build/Products/Release-iphoneos/${APP_NAME}.app/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST")
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$PLIST")

TAG="v${VERSION}"
ASSET="Pocket-Tandas-${VERSION}.ipa"

# 4. Name the artifact and compute integrity metadata.
mv -f "$IPA" "$ASSET"
SIZE=$(stat -f%z "$ASSET")
SHA256=$(shasum -a 256 "$ASSET" | awk '{print $1}')
DATE=$(date -u +%Y-%m-%d)
URL="${REL_BASE}/${TAG}/${ASSET}"
NOTES="${RELEASE_NOTES:-Bug fixes and improvements.}"

# 5. Create apps.json from a template if it doesn't exist yet.
if [ ! -f "$SOURCE_JSON" ]; then
  echo "==> ${SOURCE_JSON} not found — creating it"
  cat > "$SOURCE_JSON" <<JSON
{
  "name": "${APP_NAME}",
  "identifier": "${BUNDLE_ID}.source",
  "sourceURL": "${RAW_BASE}/${SOURCE_JSON}",
  "website": "https://github.com/${SLUG}",
  "apps": [
    {
      "name": "${APP_NAME}",
      "bundleIdentifier": "${BUNDLE_ID}",
      "developerName": "${DEVELOPER}",
      "subtitle": "Tanda player for tango DJs",
      "localizedDescription": "Pocket Tandas is a music player for Argentine tango. Organize your tracks into tandas, separate them with cortinas, and play smoothly through a milonga.",
      "iconURL": "${RAW_BASE}/${ICON_FILE}",
      "tintColor": "B5121B",
      "category": "music",
      "screenshotURLs": [],
      "versions": []
    }
  ],
  "news": []
}
JSON
fi

# 6. Inject this version into apps.json (prepend, de-dupe, keep history).
#    NOTE: keep this transform identical to .github/workflows/release.yml.
jq \
  --arg bid     "$BUNDLE_ID" \
  --arg version "$VERSION" \
  --arg build   "$BUILD" \
  --arg date    "$DATE" \
  --arg notes   "$NOTES" \
  --arg url     "$URL" \
  --argjson size "$SIZE" \
  --arg sha     "$SHA256" \
  --arg minos   "$MIN_OS" \
'
  def newver: {
    version: $version,
    buildVersion: $build,
    date: $date,
    localizedDescription: $notes,
    downloadURL: $url,
    size: $size,
    sha256: $sha,
    minOSVersion: $minos
  };
  .apps |= map(
    if .bundleIdentifier == $bid then
        .versions = ([newver] + ((.versions // [])
          | map(select(.version != $version or .buildVersion != $build))))
      | .version            = $version
      | .versionDate        = $date
      | .versionDescription = $notes
      | .downloadURL        = $url
      | .size               = $size
      | .minOSVersion       = $minos
    else . end
  )
' "$SOURCE_JSON" > "${SOURCE_JSON}.tmp" && mv "${SOURCE_JSON}.tmp" "$SOURCE_JSON"

echo
echo "✅ ${ASSET} ($(printf "%'d" "$SIZE" 2>/dev/null || echo "$SIZE") bytes) built; ${SOURCE_JSON} updated for ${VERSION}."
echo
echo "Next steps:"
echo "  1. Publish the IPA at the download URL:"
echo "       gh release create ${TAG} \"${ASSET}\" --title \"${APP_NAME} ${VERSION}\" --notes \"${NOTES}\""
echo "  2. Commit the source so AltStore can fetch it:"
echo "       git add ${SOURCE_JSON} && git commit -m \"apps.json: ${APP_NAME} ${VERSION}\" && git push"
