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
# VS Code GUI can run with a minimal PATH; include common binary dirs explicitly.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

resolve_xcodegen() {
  if command -v xcodegen >/dev/null 2>&1; then
    command -v xcodegen
    return 0
  fi

  for candidate in /opt/homebrew/bin/xcodegen /usr/local/bin/xcodegen; do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

cd "$SCRIPT_DIR"

MODE="${1:-all}"

# --- Build ---
do_build() {
  local xcodegen_bin
  if ! xcodegen_bin="$(resolve_xcodegen)"; then
    echo "❌ xcodegen not found. Install it with: brew install xcodegen"
    exit 127
  fi

  echo "📦 Generating Xcode project..."
  "$xcodegen_bin" generate

  echo "🔗 Patching local package reference..."
  "$SCRIPT_DIR/scripts/patch-local-package-reference.sh"

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
  all|"")
    do_build
    do_deploy
    ;;
  *)
    echo "❌ Unknown mode: $MODE"
    echo "Usage: ./build-and-run.sh [--build|--deploy]"
    exit 2
    ;;
esac
