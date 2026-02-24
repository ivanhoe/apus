#!/bin/bash
# Build, install, and launch ExampleApp on the simulator
# Usage: ./build-and-run.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIMULATOR_ID="F5AA85AE-0E3F-46B6-AC6E-D89984F4854B"
BUNDLE_ID="com.apus.ExampleApp"
APP_PATH="build/Build/Products/Debug-iphonesimulator/ExampleApp.app"

cd "$SCRIPT_DIR"

echo "📦 Generating Xcode project..."
xcodegen generate

echo "🔨 Building ExampleApp..."
xcodebuild -scheme ExampleApp \
  -destination "platform=iOS Simulator,name=iPhone 16e" \
  -derivedDataPath build \
  OTHER_LDFLAGS='$(inherited) -Xlinker -interposable' \
  ENABLE_DEBUG_DYLIB=NO \
  -quiet

echo "📲 Installing on simulator..."
xcrun simctl install "$SIMULATOR_ID" "$APP_PATH"

echo "🚀 Launching app..."
xcrun simctl launch "$SIMULATOR_ID" "$BUNDLE_ID"

echo "✅ Done! ExampleApp is running."
