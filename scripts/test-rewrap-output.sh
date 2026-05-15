#!/usr/bin/env bash
# test-rewrap-output.sh
# Offline verification of rewrap-xcframework.sh output.
# Implements the three "Pre-TestFlight verification" checks from
# RESEARCH.md Q4 — confirms upstream issue #6 fixes hold.

set -euo pipefail

XCF="${1:-./LiteRTLM-rewrapped.xcframework}"

if [ ! -d "$XCF" ]; then
  echo "ERROR: xcframework not found: $XCF" >&2
  exit 1
fi

SLICES=(ios-arm64 ios-arm64-simulator)

for slice in "${SLICES[@]}"; do
  FW="$XCF/$slice/CLiteRTLM.framework"
  [ -d "$FW" ] || { echo "ERROR: missing slice $FW" >&2; exit 1; }

  # 1. PlistBuddy CFBundleShortVersionString must be present + non-empty
  PLIST="$FW/Info.plist"
  VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST" 2>/dev/null || true)
  if [ -z "$VER" ]; then
    echo "FAIL [$slice]: CFBundleShortVersionString missing or empty in $PLIST" >&2
    exit 1
  fi

  # 2. No loose dylibs anywhere in the slice (must be wrapped in their own .framework)
  LOOSE_COUNT=$(find "$XCF/$slice" -name "*.dylib" -not -path "*.framework/*" | wc -l | tr -d ' ')
  if [ "$LOOSE_COUNT" -gt 0 ]; then
    echo "FAIL [$slice]: loose dylibs found:" >&2
    find "$XCF/$slice" -name "*.dylib" -not -path "*.framework/*" >&2
    exit 1
  fi

  # 3. codesign metadata is well-formed (any non-zero exit indicates malformed signature)
  if ! codesign -d --verbose=4 "$FW" >/dev/null 2>&1; then
    echo "FAIL [$slice]: codesign -d failed on $FW" >&2
    codesign -d --verbose=4 "$FW" || true
    exit 1
  fi

  # 4. dSYM bundle for CLiteRTLM emitted alongside the slice
  DSYM_COUNT=$(find "$XCF/$slice" -maxdepth 2 -name "CLiteRTLM.framework.dSYM" -type d 2>/dev/null | wc -l | tr -d ' ')
  if [ "$DSYM_COUNT" -lt 1 ]; then
    # dsymutil may have skipped on slim binaries — emit a warning, not a hard fail
    echo "WARN [$slice]: no CLiteRTLM.framework.dSYM bundle found alongside slice" >&2
  fi

  echo "OK: rewrap passes all three issue #6 fixes for slice=$slice (version=$VER)"
done

echo "==> All slices verified."
