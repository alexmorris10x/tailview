#!/bin/sh
# Xcode pre-build guard. No network, credentials, or provider access.
set -eu
fail() { echo "error: iOS identity: $*" >&2; exit 1; }
case "${CONFIGURATION:-}" in
  Debug) dev=true ;;
  Release) dev=false ;;
  *) fail "Unsupported or missing CONFIGURATION" ;;
esac
case "${TARGET_NAME:-}" in
  TailViewIOS)
    expected_bundle='com.10x.tailview.ios'
    expected_name='TailView'
    if [ "$dev" = true ]; then
      expected_bundle='com.10x.tailview.ios.dev'
      expected_name='TailView Dev'
    fi
    ;;
  TailViewLiveActivity)
    expected_bundle='com.10x.tailview.ios.LiveActivity'
    expected_name='TailView Controls'
    if [ "$dev" = true ]; then
      expected_bundle='com.10x.tailview.ios.dev.LiveActivity'
      expected_name='TailView Controls Dev'
    fi
    ;;
  *) fail "Unsupported or missing TARGET_NAME" ;;
esac
[ "${PRODUCT_BUNDLE_IDENTIFIER:-}" = "$expected_bundle" ] || fail "PRODUCT_BUNDLE_IDENTIFIER must be $expected_bundle"
[ "${APP_DISPLAY_NAME:-}" = "$expected_name" ] || fail "APP_DISPLAY_NAME must be $expected_name"
if [ "$TARGET_NAME" = TailViewIOS ]; then
  expected_icon=AppIcon
  [ "$dev" = false ] || expected_icon=AppIcon-Dev
  [ "${ASSETCATALOG_COMPILER_APPICON_NAME:-}" = "$expected_icon" ] || fail "Incorrect icon selection"
fi
echo "iOS identity verified: $TARGET_NAME $CONFIGURATION $expected_bundle"
