#!/bin/bash
# Build, install, and launch ExampleApp on the simulator.
#
# Usage:
#   ./build-and-run.sh              # build + install + launch (default)
#   ./build-and-run.sh --build      # compile only (no simulator)
#   ./build-and-run.sh --deploy     # install + launch (skip compile)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIMULATOR_ID="${SIMULATOR_ID:-F5AA85AE-0E3F-46B6-AC6E-D89984F4854B}"
BUNDLE_ID="com.apus.ExampleApp"
APP_PATH="build/Build/Products/Debug-iphonesimulator/ExampleApp.app"

cd "$SCRIPT_DIR"

MODE="${1:-all}"

# --- Build ---
do_build() {
  echo "📦 Generating Xcode project..."
  xcodegen generate

  if [ "$MODE" = "--build" ]; then
    DESTINATION="generic/platform=iOS Simulator"
  else
    DESTINATION="id=${SIMULATOR_ID}"
  fi

  echo "🔨 Building ExampleApp..."
  xcodebuild -scheme ExampleApp \
    -destination "$DESTINATION" \
    -derivedDataPath build \
    OTHER_LDFLAGS='$(inherited) -Xlinker -interposable' \
    ENABLE_DEBUG_DYLIB=NO \
    -quiet

  echo "✅ Build succeeded."
}

# --- Deploy ---
do_deploy() {
  if [ ! -d "$APP_PATH" ]; then
    echo "❌ No build found at $APP_PATH — run without --deploy first."
    exit 1
  fi

  echo "📱 Booting simulator..."
  xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true

  echo "📲 Installing on simulator..."
  xcrun simctl install "$SIMULATOR_ID" "$APP_PATH"

  echo "🚀 Launching app..."
  xcrun simctl launch "$SIMULATOR_ID" "$BUNDLE_ID"

  echo "✅ Done! ExampleApp is running."
}

# --- Main ---
case "$MODE" in
  --build)
    do_build
    ;;
  --deploy)
    do_deploy
    ;;
  *)
    do_build
    do_deploy
    ;;
esac
