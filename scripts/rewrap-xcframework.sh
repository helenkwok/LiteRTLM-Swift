#!/usr/bin/env bash
# rewrap-xcframework.sh
# Re-wraps the shipped LiteRTLM.xcframework so it passes App Store notary.
# Resolves: https://github.com/mylovelycodes/LiteRTLM-Swift/issues/6
# Run from repo root after `scripts/build-xcframework.sh` has produced the
# raw xcframework. Outputs LiteRTLM-rewrapped.xcframework next to it.
#
# Extended (Phase 14-08): also emits:
#   - rewrap-manifest.json (schema_version: 1, Option A symmetric xcframeworks array)
#   - Sources/LiteRTLMSwift/RewrapManifest.swift (AUTO-GENERATED — do not edit)
#   - Package.swift MANIFEST-MANAGED block (BOTH binaryTarget entries regenerated)
#
# Flags:
#   --tag <tag>              Tag for this release (e.g. v0.7.3+rewrap.1)
#   --upstream-version <ver> Upstream version (e.g. v0.7.3); derived from tag if omitted
#   --regenerate-only        Skip the actual rewrap work; re-emit manifest/swift/Package.swift
#                            from existing rewrapped xcframeworks on disk (fast Layer C path)
#
# Idempotency: rerunning with the same inputs produces byte-identical outputs.
# NEVER pass --tag with a placeholder; the manifest writer validates 64-hex sha256 before write.

set -euo pipefail

# ---- Argument parsing ----
TAG=""
UPSTREAM_VERSION=""
REGENERATE_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="$2"; shift 2 ;;
    --upstream-version)
      UPSTREAM_VERSION="$2"; shift 2 ;;
    --regenerate-only)
      REGENERATE_ONLY=true; shift ;;
    -*)
      echo "Unknown flag: $1" >&2; exit 1 ;;
    *)
      # Positional arg: input xcframework path (legacy compat)
      IN_XCF="$1"; shift ;;
  esac
done

IN_XCF="${IN_XCF:-Frameworks/LiteRTLM.xcframework}"
OUT_XCF="${IN_XCF%.xcframework}-rewrapped.xcframework"
GMCP_OUT="$(dirname "$OUT_XCF")/GemmaModelConstraintProvider.xcframework"
VERSION="${LITERTLM_VERSION:-0.1.0}"
BUILD="${LITERTLM_BUILD:-1}"

# ---- Capture script sha BEFORE any writes (so we don't hash our own output) ----
REWRAP_SCRIPT_SHA=$(shasum -a 256 "$0" | awk '{print $1}')

# ---- Resolve tag ----
if [ -z "$TAG" ]; then
  # Try git describe for local dev runs
  TAG=$(git describe --tags --dirty 2>/dev/null || echo "dev")
fi

# ---- Parse upstream version + iteration from tag ----
# Convention: v<upstream>+rewrap.<iteration>  e.g. v0.7.3+rewrap.1
if [ -z "$UPSTREAM_VERSION" ]; then
  if [[ "$TAG" =~ ^(v[^+]+)\+rewrap\.([0-9]+)$ ]]; then
    UPSTREAM_VERSION="${BASH_REMATCH[1]}"
    REWRAP_ITERATION="${BASH_REMATCH[2]}"
  else
    UPSTREAM_VERSION="$TAG"
    REWRAP_ITERATION="0"
  fi
else
  if [[ "$TAG" =~ \+rewrap\.([0-9]+)$ ]]; then
    REWRAP_ITERATION="${BASH_REMATCH[1]}"
  else
    REWRAP_ITERATION="0"
  fi
fi

FORK_SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
BUILT_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

REPO_URL="https://github.com/helenkwok/LiteRTLM-Swift"

# ---- Skip rewrap work if --regenerate-only ----
if [ "$REGENERATE_ONLY" = false ]; then

  echo "==> Re-wrap: $IN_XCF -> $OUT_XCF (version $VERSION, build $BUILD)"

  WORK="$(mktemp -d)"

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
  rm -rf "$OUT_XCF"
  CL_ARGS=()
  for slice in "${SLICES[@]}"; do
    CL_ARGS+=(-framework "$WORK/$slice/CLiteRTLM.framework")
    if [ -d "$WORK/$slice/CLiteRTLM.framework.dSYM" ]; then
      CL_ARGS+=(-debug-symbols "$WORK/$slice/CLiteRTLM.framework.dSYM")
    fi
  done
  xcodebuild -create-xcframework "${CL_ARGS[@]}" -output "$OUT_XCF"

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

fi  # end REGENERATE_ONLY=false block

# ---- Zip both xcframeworks ----
echo "==> Zipping xcframeworks for tag $TAG"

# Map xcframework output paths to their names and target names
declare -a XCF_NAMES=("LiteRTLM-rewrapped.xcframework" "GemmaModelConstraintProvider.xcframework")
declare -a XCF_PATHS=("$OUT_XCF" "$GMCP_OUT")
declare -a XCF_SWIFT_TARGETS=("LiteRTLMBinary" "GemmaModelConstraintProviderBinary")

declare -a ZIP_FILENAMES=()
declare -a ZIP_SHA256S=()

for i in 0 1; do
  xcf_name="${XCF_NAMES[$i]}"
  xcf_path="${XCF_PATHS[$i]}"
  swift_target="${XCF_SWIFT_TARGETS[$i]}"
  zip_filename="${xcf_name%.xcframework}-${TAG}.xcframework.zip"

  if [ ! -d "$xcf_path" ]; then
    echo "FAIL: xcframework not found at $xcf_path — cannot zip (run without --regenerate-only first)" >&2
    exit 1
  fi

  # Zip from the parent directory so the xcframework name is the zip root
  xcf_dir="$(dirname "$xcf_path")"
  xcf_basename="$(basename "$xcf_path")"
  (cd "$xcf_dir" && zip -qr "$OLDPWD/$zip_filename" "$xcf_basename")

  zip_sha=$(shasum -a 256 "$zip_filename" | awk '{print $1}')

  # Hard validation: 64-hex non-empty
  if ! [[ "$zip_sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "FAIL: refusing to write manifest with placeholder/empty sha256 for $xcf_name — got: '$zip_sha'" >&2
    exit 1
  fi

  ZIP_FILENAMES+=("$zip_filename")
  ZIP_SHA256S+=("$zip_sha")

  echo "  $xcf_name -> $zip_filename (sha256: ${zip_sha:0:16}...)"
done

# ---- Collect install_names per xcframework ----
declare -a INSTALL_NAMES_0=()
declare -a INSTALL_NAMES_1=()

_collect_install_names() {
  local xcf_path="$1"
  local arr_name="$2"
  local -a names=()
  # Find all binary files (executables/dylibs) inside the xcframework
  while IFS= read -r -d '' binary; do
    # Use otool -D to get the install_name (LC_ID_DYLIB)
    local iname
    iname=$(otool -D "$binary" 2>/dev/null | tail -1 | xargs 2>/dev/null || true)
    if [ -n "$iname" ] && [[ "$iname" == @rpath/* ]]; then
      # Check not already in list
      local already=false
      for n in "${names[@]+"${names[@]}"}"; do
        [ "$n" = "$iname" ] && already=true && break
      done
      [ "$already" = false ] && names+=("$iname")
    fi
  done < <(find "$xcf_path" -type f \( -name "*.dylib" -o -perm +111 \) -print0 2>/dev/null | grep -v '__MACOSX' | sort -z)
  # Sort for determinism
  IFS=$'\n' sorted=($(printf '%s\n' "${names[@]+"${names[@]}"}"|sort -u)); unset IFS
  # Assign to caller's array via nameref
  eval "${arr_name}=(\"\${sorted[@]+\${sorted[@]}}\")"
}

_collect_install_names "${XCF_PATHS[0]}" INSTALL_NAMES_0
_collect_install_names "${XCF_PATHS[1]}" INSTALL_NAMES_1

# ---- Build install_names JSON arrays (sorted for determinism) ----
# Bash 3.2 compatible: namerefs (local -n) require bash 4.3+, but macOS ships
# 3.2 and GitHub Actions macos-latest is the same. Use indirect array
# expansion via eval instead.
_build_json_array() {
  local arr_name="$1"
  # Snapshot the array's contents into a local copy via eval (3.2 safe).
  local items=()
  eval "items=( \"\${${arr_name}[@]+\"\${${arr_name}[@]}\"}\" )"
  if [ "${#items[@]}" -eq 0 ]; then
    echo "[]"
    return
  fi
  local json="["
  local first=true
  local item
  for item in "${items[@]}"; do
    [ "$first" = true ] && first=false || json+=","
    json+="\"$item\""
  done
  json+="]"
  echo "$json"
}

INSTALL_NAMES_JSON_0=$(_build_json_array INSTALL_NAMES_0)
INSTALL_NAMES_JSON_1=$(_build_json_array INSTALL_NAMES_1)

# ---- Write rewrap-manifest.json (Option A symmetric xcframeworks array) ----
echo "==> Writing rewrap-manifest.json"

MANIFEST_PATH="rewrap-manifest.json"

# Build the xcframeworks JSON array using jq
XCF_ENTRY_0=$(jq -n \
  --arg name "${XCF_NAMES[0]}" \
  --arg swift_target "${XCF_SWIFT_TARGETS[0]}" \
  --arg zip_filename "${ZIP_FILENAMES[0]}" \
  --arg zip_sha256 "${ZIP_SHA256S[0]}" \
  --arg release_asset_url "${REPO_URL}/releases/download/${TAG}/${ZIP_FILENAMES[0]}" \
  --argjson install_names "$INSTALL_NAMES_JSON_0" \
  '{
    name: $name,
    swift_target_name: $swift_target,
    zip_filename: $zip_filename,
    zip_sha256: $zip_sha256,
    release_asset_url: $release_asset_url,
    install_names: $install_names
  }')

XCF_ENTRY_1=$(jq -n \
  --arg name "${XCF_NAMES[1]}" \
  --arg swift_target "${XCF_SWIFT_TARGETS[1]}" \
  --arg zip_filename "${ZIP_FILENAMES[1]}" \
  --arg zip_sha256 "${ZIP_SHA256S[1]}" \
  --arg release_asset_url "${REPO_URL}/releases/download/${TAG}/${ZIP_FILENAMES[1]}" \
  --argjson install_names "$INSTALL_NAMES_JSON_1" \
  '{
    name: $name,
    swift_target_name: $swift_target,
    zip_filename: $zip_filename,
    zip_sha256: $zip_sha256,
    release_asset_url: $release_asset_url,
    install_names: $install_names
  }')

XCF_ARRAY=$(jq -n --argjson e0 "$XCF_ENTRY_0" --argjson e1 "$XCF_ENTRY_1" '[$e0, $e1]')

jq -n \
  --argjson schema_version 1 \
  --arg upstream_version "$UPSTREAM_VERSION" \
  --argjson rewrap_iteration "$REWRAP_ITERATION" \
  --arg tag "$TAG" \
  --arg fork_sha "$FORK_SHA" \
  --arg rewrap_script_sha "$REWRAP_SCRIPT_SHA" \
  --arg built_at "$BUILT_AT" \
  --argjson xcframeworks "$XCF_ARRAY" \
  '{
    schema_version: $schema_version,
    upstream_version: $upstream_version,
    rewrap_iteration: $rewrap_iteration,
    tag: $tag,
    fork_sha: $fork_sha,
    rewrap_script_sha: $rewrap_script_sha,
    built_at: $built_at,
    xcframeworks: $xcframeworks
  }' > "$MANIFEST_PATH"

echo "  rewrap-manifest.json written"

# ---- Post-write sha256 validation ----
# For each entry in the just-written manifest, re-derive zip_sha256 from the zip on disk
echo "==> Post-write sha256 validation"
count=$(jq '.xcframeworks | length' "$MANIFEST_PATH")
for i in $(seq 0 $((count - 1))); do
  name=$(jq -r ".xcframeworks[$i].name" "$MANIFEST_PATH")
  zip_fn=$(jq -r ".xcframeworks[$i].zip_filename" "$MANIFEST_PATH")
  manifest_sha=$(jq -r ".xcframeworks[$i].zip_sha256" "$MANIFEST_PATH")
  disk_sha=$(shasum -a 256 "$zip_fn" | awk '{print $1}')
  if [ "$disk_sha" != "$manifest_sha" ]; then
    echo "FAIL: post-write sha256 mismatch for $name — manifest=$manifest_sha disk=$disk_sha" >&2
    exit 1
  fi
  echo "  ✓ $name sha256 verified"
done

# ---- Regenerate Sources/LiteRTLMSwift/RewrapManifest.swift ----
echo "==> Regenerating Sources/LiteRTLMSwift/RewrapManifest.swift"

SWIFT_FILE="Sources/LiteRTLMSwift/RewrapManifest.swift"
mkdir -p "$(dirname "$SWIFT_FILE")"

# Build Swift entries from manifest
SWIFT_ENTRIES=""
for i in $(seq 0 $((count - 1))); do
  xcf_name=$(jq -r ".xcframeworks[$i].name" "$MANIFEST_PATH")
  swift_target=$(jq -r ".xcframeworks[$i].swift_target_name" "$MANIFEST_PATH")
  sha=$(jq -r ".xcframeworks[$i].zip_sha256" "$MANIFEST_PATH")
  url=$(jq -r ".xcframeworks[$i].release_asset_url" "$MANIFEST_PATH")
  SWIFT_ENTRIES+="        Entry(xcframeworkName: \"$xcf_name\","$'\n'
  SWIFT_ENTRIES+="              swiftTargetName: \"$swift_target\","$'\n'
  SWIFT_ENTRIES+="              zipSHA256: \"$sha\","$'\n'
  SWIFT_ENTRIES+="              releaseAssetURL: \"$url\"),"$'\n'
done

cat > "$SWIFT_FILE" <<SWIFT_EOF
// AUTO-GENERATED by scripts/rewrap-xcframework.sh — do not edit by hand.
// Re-run the script with --tag <tag> to regenerate.
// Schema: Phase 14-08, D-31 (generated-source approach for SPM ergonomics).

import Foundation

public enum RewrapManifest {
    public struct Entry {
        public let xcframeworkName: String
        public let swiftTargetName: String
        public let zipSHA256: String
        public let releaseAssetURL: String
        public init(xcframeworkName: String, swiftTargetName: String,
                    zipSHA256: String, releaseAssetURL: String) {
            self.xcframeworkName = xcframeworkName
            self.swiftTargetName = swiftTargetName
            self.zipSHA256 = zipSHA256
            self.releaseAssetURL = releaseAssetURL
        }
    }
    public static let schemaVersion = 1
    public static let upstreamVersion = "$(jq -r .upstream_version "$MANIFEST_PATH")"
    public static let tag = "$(jq -r .tag "$MANIFEST_PATH")"
    public static let forkSHA = "$(jq -r .fork_sha "$MANIFEST_PATH")"
    public static let entries: [Entry] = [
$SWIFT_ENTRIES    ]
}
SWIFT_EOF

echo "  RewrapManifest.swift written"

# ---- Regenerate Package.swift MANIFEST-MANAGED block ----
echo "==> Regenerating Package.swift MANIFEST-MANAGED block"

if [ ! -f "Package.swift" ]; then
  echo "FAIL: Package.swift not found — run from repo root" >&2
  exit 1
fi

# Build the new MANIFEST-MANAGED content
MANAGED_CONTENT="        // MANIFEST-MANAGED:BEGIN — regenerated by scripts/rewrap-xcframework.sh; do NOT hand-edit between these markers."$'\n'

for i in $(seq 0 $((count - 1))); do
  swift_target=$(jq -r ".xcframeworks[$i].swift_target_name" "$MANIFEST_PATH")
  url=$(jq -r ".xcframeworks[$i].release_asset_url" "$MANIFEST_PATH")
  sha=$(jq -r ".xcframeworks[$i].zip_sha256" "$MANIFEST_PATH")
  MANAGED_CONTENT+="        .binaryTarget("$'\n'
  MANAGED_CONTENT+="            name: \"$swift_target\","$'\n'
  MANAGED_CONTENT+="            url: \"$url\","$'\n'
  MANAGED_CONTENT+="            checksum: \"$sha\""$'\n'
  MANAGED_CONTENT+="        ),"$'\n'
done
MANAGED_CONTENT+="        // MANIFEST-MANAGED:END"

# Splice the MANIFEST-MANAGED block into Package.swift portably.
# Why not `awk -v new_block="$MANAGED_CONTENT"`: BSD awk on macOS does not
# accept embedded newlines in `-v` assignments (errors with "newline in
# string"). GitHub Actions `macos-latest` has the same BSD awk.
# Strategy: dump the multiline replacement to a temp file, then split
# Package.swift at the sentinels and stitch head + temp + tail.
TMP_PKG="$(mktemp)"
TMP_NEW="$(mktemp)"
printf '%s\n' "$MANAGED_CONTENT" > "$TMP_NEW"
awk -v new_block_file="$TMP_NEW" '
  # Insert the new block at the FIRST BEGIN we see. Any additional
  # BEGIN/END pairs (e.g., from prior corrupted writes) are treated as
  # stale blocks and consumed without re-emitting. End result is
  # idempotent: N input blocks collapse to exactly one output block.
  /MANIFEST-MANAGED:BEGIN/ {
    if (!inserted) {
      while ((getline line < new_block_file) > 0) print line
      close(new_block_file)
      inserted = 1
    }
    in_block = 1
    next
  }
  /MANIFEST-MANAGED:END/ { in_block = 0; next }
  !in_block { print }
' "Package.swift" > "$TMP_PKG"
mv "$TMP_PKG" "Package.swift"
rm -f "$TMP_NEW"

echo "  Package.swift MANIFEST-MANAGED block regenerated"

# ---- Post-write Package.swift validation ----
# Count binaryTarget entries inside the managed block
managed_block=$(awk '/MANIFEST-MANAGED:BEGIN/,/MANIFEST-MANAGED:END/' "Package.swift")
binary_target_count=$(echo "$managed_block" | grep -c '\.binaryTarget(' || true)
if [ "$binary_target_count" -ne 2 ]; then
  echo "FAIL: Package.swift managed block has $binary_target_count binaryTarget entries, expected 2" >&2
  exit 1
fi

# Assert neither checksum is a placeholder
for i in $(seq 0 $((count - 1))); do
  sha=$(jq -r ".xcframeworks[$i].zip_sha256" "$MANIFEST_PATH")
  swift_target=$(jq -r ".xcframeworks[$i].swift_target_name" "$MANIFEST_PATH")
  if [[ "$sha" == "<"* ]] || [ -z "$sha" ] || ! [[ "$sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "FAIL: Package.swift managed block has placeholder/invalid checksum for $swift_target: $sha" >&2
    exit 1
  fi
done

echo "  Package.swift validation passed ($binary_target_count binaryTarget entries, no placeholder checksums)"
echo "==> Phase 14-08: rewrap-manifest.json + RewrapManifest.swift + Package.swift all regenerated from tag $TAG"
