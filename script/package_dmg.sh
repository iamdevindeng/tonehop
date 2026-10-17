#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s /path/to/Release/ToneHop.app /path/to/output.dmg\n' "$0"
  printf 'Packages an existing signed Release app; never builds or launches it.\n'
  printf 'Creates output.dmg and output.dmg.sha256; existing outputs are refused.\n'
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [[ "$#" -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then
  usage
  exit 0
fi
if [[ "$#" -ne 2 ]]; then
  usage >&2
  exit 2
fi
[[ "$(/usr/bin/uname -s)" == Darwin ]] || fail 'DMG packaging requires macOS.'
[[ -d "$1" ]] || fail "App bundle does not exist: $1"
APP_BUNDLE="$(cd "$1" && pwd -P)"
[[ "${APP_BUNDLE##*/}" == ToneHop.app ]] || fail 'Input must be ToneHop.app.'
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
BUILD_INFO="$APP_BUNDLE/Contents/Resources/BuildInfo.json"
[[ -f "$INFO_PLIST" ]] || fail 'App bundle has no Info.plist.'
[[ -f "$BUILD_INFO" ]] || fail 'App bundle has no BuildInfo.json.'

read_value() {
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null \
    || fail "Cannot read $2 from $1"
}

[[ "$(read_value "$INFO_PLIST" CFBundleIdentifier)" == com.dengziyi.ToneHop ]] \
  || fail 'Wrong app bundle identifier.'
[[ "$(read_value "$INFO_PLIST" CFBundlePackageType)" == APPL ]] \
  || fail 'Input is not an application bundle.'
[[ "$(read_value "$INFO_PLIST" CFBundleExecutable)" == ToneHop ]] \
  || fail 'Unexpected app executable.'
[[ -x "$APP_BUNDLE/Contents/MacOS/ToneHop" ]] || fail 'App executable is missing.'
[[ "$(read_value "$BUILD_INFO" configuration)" == Release ]] \
  || fail 'BuildInfo configuration must be Release.'
APP_VERSION="$(read_value "$INFO_PLIST" CFBundleShortVersionString)"
BUILD_VERSION="$(read_value "$BUILD_INFO" applicationVersion)"
APP_BUILD="$(read_value "$INFO_PLIST" CFBundleVersion)"
BUILD_NUMBER="$(read_value "$BUILD_INFO" buildNumber)"
[[ "$APP_VERSION" == "$BUILD_VERSION" ]] \
  || fail 'App version does not match BuildInfo.'
[[ "$APP_BUILD" == "$BUILD_NUMBER" ]] \
  || fail 'App build number does not match BuildInfo.'
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" \
  || fail 'App signature is invalid.'

OUTPUT_INPUT="$2"
[[ "$OUTPUT_INPUT" == /* ]] || OUTPUT_INPUT="$PWD/$OUTPUT_INPUT"
# Reject parent traversal before mkdir: resolving only an existing ancestor
# cannot account for a missing directory followed by /../ into the input app.
case "$OUTPUT_INPUT" in
  */../*) fail 'Output path must not contain .. components.' ;;
esac
OUTPUT_NAME="${OUTPUT_INPUT##*/}"
[[ "$OUTPUT_NAME" == *.dmg ]] || fail 'Output filename must end in .dmg.'
# Keep the checksum sidecar a single, portable shasum record.
[[ "$OUTPUT_NAME" != *$'\n'* && "$OUTPUT_NAME" != *$'\r'* && "$OUTPUT_NAME" != *'\'* ]] \
  || fail 'Output filename cannot contain newlines or backslashes.'
OUTPUT_PARENT="$(/usr/bin/dirname "$OUTPUT_INPUT")"

# Check the nearest existing parent before creating directories, so even a
# missing output directory reached through a symlink cannot alter the input app.
EXISTING_PARENT="$OUTPUT_PARENT"
while [[ ! -d "$EXISTING_PARENT" ]]; do
  [[ ! -e "$EXISTING_PARENT" && ! -L "$EXISTING_PARENT" ]] \
    || fail "Output parent is not a directory: $EXISTING_PARENT"
  EXISTING_PARENT="$(/usr/bin/dirname "$EXISTING_PARENT")"
done
EXISTING_PARENT="$(cd "$EXISTING_PARENT" && pwd -P)"
case "$EXISTING_PARENT/" in
  "$APP_BUNDLE/"*) fail 'Output must be outside the input app bundle.' ;;
esac
/bin/mkdir -p "$OUTPUT_PARENT"
OUTPUT_PARENT="$(cd "$OUTPUT_PARENT" && pwd -P)"
case "$OUTPUT_PARENT/" in
  "$APP_BUNDLE/"*) fail 'Output must be outside the input app bundle.' ;;
esac
OUTPUT_DMG="$OUTPUT_PARENT/$OUTPUT_NAME"
OUTPUT_SHA="$OUTPUT_DMG.sha256"
for destination in "$OUTPUT_DMG" "$OUTPUT_SHA"; do
  [[ ! -e "$destination" && ! -L "$destination" ]] \
    || fail "Refusing to overwrite existing output: $destination"
done

# Keeping the temporary image on the destination filesystem permits atomic,
# no-overwrite publication via hard links, including concurrent invocations.
WORK_DIR="$(/usr/bin/mktemp -d "$OUTPUT_PARENT/.ToneHop-package.XXXXXX")"
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$status" -ne 0 ]]; then
    # Remove only files this invocation published, never another invocation's.
    if [[ "$OUTPUT_DMG" -ef "$WORK_DIR/ToneHop.dmg" ]]; then
      /bin/rm -f "$OUTPUT_DMG"
    fi
    if [[ "$OUTPUT_SHA" -ef "$WORK_DIR/ToneHop.dmg.sha256" ]]; then
      /bin/rm -f "$OUTPUT_SHA"
    fi
  fi
  /bin/rm -rf "$WORK_DIR"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

STAGING_DIR="$WORK_DIR/staging"
/bin/mkdir "$STAGING_DIR"
/usr/bin/ditto --rsrc --extattr --qtn --acl "$APP_BUNDLE" "$STAGING_DIR/ToneHop.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGING_DIR/ToneHop.app" \
  || fail 'Staged app signature is invalid.'
/bin/ln -s /Applications "$STAGING_DIR/Applications"
/usr/bin/hdiutil create -volname ToneHop -srcfolder "$STAGING_DIR" \
  -fs HFS+ -format UDZO "$WORK_DIR/ToneHop.dmg"
/usr/bin/hdiutil verify "$WORK_DIR/ToneHop.dmg"
# Hash stdin so special characters in a parent directory cannot add shasum's
# filename-escaping prefix to the digest written into the sidecar.
DMG_HASH="$(/usr/bin/shasum -a 256 < "$WORK_DIR/ToneHop.dmg")"
DMG_HASH="${DMG_HASH%% *}"
printf '%s  %s\n' "$DMG_HASH" "$OUTPUT_NAME" > "$WORK_DIR/ToneHop.dmg.sha256"
/bin/ln "$WORK_DIR/ToneHop.dmg" "$OUTPUT_DMG"
/bin/ln "$WORK_DIR/ToneHop.dmg.sha256" "$OUTPUT_SHA"
printf 'Created: %s\nSHA-256: %s\nChecksum file: %s\n' "$OUTPUT_DMG" "$DMG_HASH" "$OUTPUT_SHA"
