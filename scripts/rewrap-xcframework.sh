#!/usr/bin/env bash
# rewrap-xcframework.sh
# Re-wraps the shipped LiteRTLM.xcframework so it passes App Store notary.
# Resolves: https://github.com/mylovelycodes/LiteRTLM-Swift/issues/6
# Run from repo root after `scripts/build-xcframework.sh` has produced the
# raw xcframework. Outputs LiteRTLM-rewrapped.xcframework next to it.

set -euo pipefail

IN_XCF="${1:-Frameworks/LiteRTLM.xcframework}"
OUT_XCF="${IN_XCF%.xcframework}-rewrapped.xcframework"
WORK="$(mktemp -d)"
VERSION="${LITERTLM_VERSION:-0.1.0}"   # CFBundleShortVersionString
BUILD="${LITERTLM_BUILD:-1}"            # CFBundleVersion

echo "==> Re-wrap: $IN_XCF -> $OUT_XCF (version $VERSION, build $BUILD)"

SLICES=(ios-arm64 ios-arm64-simulator)

for slice in "${SLICES[@]}"; do
  SRC_FW="$IN_XCF/$slice/CLiteRTLM.framework"
  [ -d "$SRC_FW" ] || { echo "missing slice: $SRC_FW"; exit 1; }

  DST_DIR="$WORK/$slice"
  mkdir -p "$DST_DIR"
  cp -R "$SRC_FW" "$DST_DIR/"
  FW="$DST_DIR/CLiteRTLM.framework"

  # ---- Fix 1: Info.plist CFBundleShortVersionString injection ----
  PLIST="$FW/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST"

  # ---- Fix 2: extract loose dylib into its own framework ----
  LOOSE="$FW/libGemmaModelConstraintProvider.dylib"
  if [ -f "$LOOSE" ]; then
    GMCP_FW="$DST_DIR/GemmaModelConstraintProvider.framework"
    mkdir -p "$GMCP_FW/Headers"
    mv "$LOOSE" "$GMCP_FW/GemmaModelConstraintProvider"
    install_name_tool -id \
      "@rpath/GemmaModelConstraintProvider.framework/GemmaModelConstraintProvider" \
      "$GMCP_FW/GemmaModelConstraintProvider"
    cat > "$GMCP_FW/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>GemmaModelConstraintProvider</string>
  <key>CFBundleIdentifier</key><string>com.google.ai.edge.gemmaModelConstraintProvider</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>GemmaModelConstraintProvider</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>MinimumOSVersion</key><string>17.0</string>
</dict></plist>
EOF
    codesign --force --sign - --timestamp=none "$GMCP_FW/GemmaModelConstraintProvider"

    # ---- Fix 2b: patch CLiteRTLM's LC_LOAD_DYLIB to point at the new framework path ----
    install_name_tool -change \
      "@rpath/libGemmaModelConstraintProvider.dylib" \
      "@rpath/GemmaModelConstraintProvider.framework/GemmaModelConstraintProvider" \
      "$FW/CLiteRTLM"
  fi

  # ---- Fix 3: dSYMs ----
  DSYM_OUT="$WORK/$slice/CLiteRTLM.framework.dSYM"
  dsymutil "$FW/CLiteRTLM" -o "$DSYM_OUT" || echo "dsymutil note: $? (continuing)"
  if [ -d "$DST_DIR/GemmaModelConstraintProvider.framework" ]; then
    dsymutil "$DST_DIR/GemmaModelConstraintProvider.framework/GemmaModelConstraintProvider" \
      -o "$WORK/$slice/GemmaModelConstraintProvider.framework.dSYM" || true
  fi

  # Re-sign CLiteRTLM after Info.plist mutation
  codesign --force --sign - --timestamp=none "$FW/CLiteRTLM"
done

# ---- Assemble xcframeworks ----
# `xcodebuild -create-xcframework` allows only ONE framework per platform
# identifier, so CLiteRTLM and GemmaModelConstraintProvider must each ship as
# their own xcframework. Consumers (e.g. expo-litert-lm/ios/Frameworks/) embed
# both peers. GMCP may exist on only a subset of slices (currently ios-arm64).

rm -rf "$OUT_XCF"
CL_ARGS=()
for slice in "${SLICES[@]}"; do
  CL_ARGS+=(-framework "$WORK/$slice/CLiteRTLM.framework")
  if [ -d "$WORK/$slice/CLiteRTLM.framework.dSYM" ]; then
    CL_ARGS+=(-debug-symbols "$WORK/$slice/CLiteRTLM.framework.dSYM")
  fi
done
xcodebuild -create-xcframework "${CL_ARGS[@]}" -output "$OUT_XCF"

GMCP_OUT="$(dirname "$OUT_XCF")/GemmaModelConstraintProvider.xcframework"
rm -rf "$GMCP_OUT"
GMCP_ARGS=()
for slice in "${SLICES[@]}"; do
  if [ -d "$WORK/$slice/GemmaModelConstraintProvider.framework" ]; then
    GMCP_ARGS+=(-framework "$WORK/$slice/GemmaModelConstraintProvider.framework")
    if [ -d "$WORK/$slice/GemmaModelConstraintProvider.framework.dSYM" ]; then
      GMCP_ARGS+=(-debug-symbols "$WORK/$slice/GemmaModelConstraintProvider.framework.dSYM")
    fi
  fi
done
if [ "${#GMCP_ARGS[@]}" -gt 0 ]; then
  xcodebuild -create-xcframework "${GMCP_ARGS[@]}" -output "$GMCP_OUT"
fi

# ---- Verification ----
echo "==> Verifying $OUT_XCF"
for slice in "${SLICES[@]}"; do
  PLIST="$OUT_XCF/$slice/CLiteRTLM.framework/Info.plist"
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST"
  codesign -d --verbose=4 "$OUT_XCF/$slice/CLiteRTLM.framework" 2>&1 | head -5
done
echo "==> Done. Consumers must embed BOTH CLiteRTLM.framework AND GemmaModelConstraintProvider.framework."

rm -rf "$WORK"
