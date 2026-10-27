#!/bin/sh
set -eu
# Xcode 26 creates an embedded dynamic stub for ONNX Runtime's static SwiftPM
# framework. Its binary inherits the app deployment target, but its copied plist
# retains upstream's older minimum. Align the declared minimum with that actual
# binary before signing the app (App Store validation error 90208).
[ "${PLATFORM_NAME:-}" = iphoneos ] || exit 0
openread_framework="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/onnxruntime.framework"
[ -f "$openread_framework/onnxruntime" ] || exit 0
openread_minimum=$(xcrun vtool -show-build "$openread_framework/onnxruntime" | /usr/bin/awk '$1 == "minos" { print $2; exit }')
[ -n "$openread_minimum" ] || { echo 'Could not inspect the ONNX framework minimum iOS version.' >&2; exit 1; }
openread_declared=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$openread_framework/Info.plist")
[ "$openread_declared" != "$openread_minimum" ] || exit 0
/usr/libexec/PlistBuddy -c "Set :MinimumOSVersion $openread_minimum" "$openread_framework/Info.plist"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der --timestamp=none "$openread_framework"
fi
echo "Aligned ONNX framework metadata with iOS $openread_minimum."
