#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEME="AWS CLI Gateway"
CONFIGURATION="${1:-Release}"
DERIVED_DATA="$SCRIPT_DIR/build"
APP_NAME="Gateway.app"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

echo "=== Building $SCHEME ($CONFIGURATION) ==="

xcodebuild \
  -project "$SCRIPT_DIR/AWS CLI Gateway.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY="$CODESIGN_IDENTITY" \
  CODE_SIGNING_ALLOWED=YES \
  clean build 2>&1 | tail -20

APP_PATH=$(find "$DERIVED_DATA" -name "$APP_NAME" -type d | head -1)
if [ -z "$APP_PATH" ]; then
  echo "ERROR: Build failed — .app not found"
  exit 1
fi

OUTPUT_DIR="$SCRIPT_DIR/output"
mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/$APP_NAME"
cp -R "$APP_PATH" "$OUTPUT_DIR/"

codesign --force --deep --sign "$CODESIGN_IDENTITY" "$OUTPUT_DIR/$APP_NAME"

echo ""
echo "=== Build Complete ==="
echo "App: $OUTPUT_DIR/$APP_NAME"
echo ""
echo "Install: cp -R \"$OUTPUT_DIR/$APP_NAME\" /Applications/"
