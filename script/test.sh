#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  printf 'Usage: %s [additional xcodebuild test options]\n' "$0"
  printf 'Runs hosted unit tests with fake audio providers. Results are saved under build/TestResults.\n'
  exit 0
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD_ROOT="$PROJECT_ROOT/build"
DERIVED_DATA_PATH="$BUILD_ROOT/DerivedData.noindex"
RESULT_STAMP="$(date '+%Y%m%d-%H%M%S')-$$"
RESULT_BUNDLE="$BUILD_ROOT/TestResults/ToneHop-$RESULT_STAMP.xcresult"
TEST_LOG="$BUILD_ROOT/logs/test-$RESULT_STAMP.log"
mkdir -p "$BUILD_ROOT/TestResults" "$BUILD_ROOT/logs"

printf 'Running ToneHopTests; results: %s\n' "$RESULT_BUNDLE"
# The scheme also sets this flag for tests started inside Xcode. The host app
# must honor it by skipping real device service startup; test cases inject fakes.
export TONEHOP_TESTING=1
/usr/bin/xcodebuild \
  -project "$PROJECT_ROOT/ToneHop/ToneHop.xcodeproj" \
  -scheme ToneHop \
  -configuration Debug \
  -sdk macosx \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -resultBundlePath "$RESULT_BUNDLE" \
  -parallel-testing-enabled NO \
  test "$@" 2>&1 | /usr/bin/tee "$TEST_LOG"
