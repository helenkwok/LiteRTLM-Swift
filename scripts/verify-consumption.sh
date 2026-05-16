#!/usr/bin/env bash
# verify-consumption.sh
# Local runner for Layer A (fresh-checkout swift build), Layer B (static grep gate),
# and Layer C (manifest-vs-Package.swift consistency check).
#
# All three layers must pass (exit 0) for the script to succeed.
# Run from repo root or via `make verify`.
#
# Flags:
#   --url-mode   Layer A uses .package(url:, from:) instead of .package(path:).
#                Used by release.yml post-release verification step.
#                Requires the JUST-PUBLISHED Release to be publicly accessible.
#   --skip-layer-a
#                Run only Layer B/C. Used before release assets exist.
#
# NOTE ON LAYER A:
#   - Locally (without --url-mode): uses path-mode binaryTarget since the Release
#     may not exist yet during development. This proves the Swift module resolves.
#   - In CI (release.yml final step, --url-mode): uses URL-mode against the just-
#     published GitHub Release. This is the definitive end-to-end proof.
#   - The binary artifacts are iOS-only xcframeworks, so Layer A builds an iOS
#     triple with the iPhoneOS SDK instead of the host macOS target.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

URL_MODE=false
SKIP_LAYER_A=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url-mode) URL_MODE=true; shift ;;
    --skip-layer-a) SKIP_LAYER_A=true; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

ERRORS=0

# =============================================================================
# Layer B: static grep gate (fast — runs first, gates the rest)
# =============================================================================
echo ""
echo "==> Layer B: static grep gate"

# Filter out comments and blank lines from allowlist before passing to grep -f
ALLOWLIST="$SCRIPT_DIR/grep-allowlist.txt"
ACTIVE_PATTERNS_FILE="$(mktemp)"
trap "rm -f $ACTIVE_PATTERNS_FILE" EXIT

if [ -f "$ALLOWLIST" ]; then
  grep -vE '^(#|$)' "$ALLOWLIST" > "$ACTIVE_PATTERNS_FILE" || true
fi

set +e
if [ -s "$ACTIVE_PATTERNS_FILE" ]; then
  # Allowlist has active patterns — exclude matching lines
  hits=$(grep -rnE 'LiteRTLM\.xcframework' \
    --include='*.swift' --include='*.json' --include='*.podspec' \
    --include='*.rb' --include='*.sh' --include='*.txt' \
    . 2>/dev/null \
    | grep -vE '(CLiteRTLM|LiteRTLM-rewrapped)' \
    | grep -E -v -f "$ACTIVE_PATTERNS_FILE" || true)
else
  # Empty or all-comment allowlist — no exclusions
  hits=$(grep -rnE 'LiteRTLM\.xcframework' \
    --include='*.swift' --include='*.json' --include='*.podspec' \
    --include='*.rb' --include='*.sh' --include='*.txt' \
    . 2>/dev/null \
    | grep -vE '(CLiteRTLM|LiteRTLM-rewrapped)' || true)
fi
set -e

if [ -n "$hits" ]; then
  echo "FAIL: raw LiteRTLM.xcframework references outside the allowlist:" >&2
  echo "$hits" >&2
  ERRORS=$((ERRORS + 1))
else
  echo "  PASS: no raw LiteRTLM.xcframework references outside allowlist"
fi

# =============================================================================
# Layer C: manifest single-source-of-truth (BOTH xcframeworks)
# =============================================================================
echo ""
echo "==> Layer C: manifest single-source-of-truth"

MANIFEST="$REPO_ROOT/rewrap-manifest.json"
SWIFT_FILE="$REPO_ROOT/Sources/LiteRTLMSwift/RewrapManifest.swift"

if [ ! -f "$MANIFEST" ]; then
  echo "FAIL: rewrap-manifest.json not found — run scripts/rewrap-xcframework.sh --tag <tag> first" >&2
  ERRORS=$((ERRORS + 1))
else
  # Drift detection is content-based, not regen-based: assert that each manifest
  # xcframework entry's checksum + URL + target name appears verbatim in
  # Package.swift's MANIFEST-MANAGED block. This catches the failure mode the
  # plan is built to prevent ("rewrap landed but Package.swift never updated")
  # without needing a clean git tree or a regen-and-diff cycle that is fragile
  # against timestamp + git-describe-dirty drift.
  #
  # If the manifest entries are reflected in Package.swift, there is no drift.
  # If not, drift is concrete and the diff is meaningful.
  managed_block=$(awk '/^[[:space:]]+\/\/ MANIFEST-MANAGED:BEGIN/,/^[[:space:]]+\/\/ MANIFEST-MANAGED:END/' "Package.swift")
  xcf_count=$(jq '.xcframeworks | length' "$MANIFEST")
  if [ "$xcf_count" -lt 2 ]; then
    echo "FAIL: manifest.xcframeworks has $xcf_count entries, expected >=2" >&2
    ERRORS=$((ERRORS + 1))
  else
    echo "  Checking $xcf_count xcframework entries in managed block..."
    layer_c_ok=true
    while IFS=$'\t' read -r tgt sha url; do
      if ! echo "$managed_block" | grep -qF "\"$sha\""; then
        echo "FAIL: Package.swift managed block missing checksum $sha for $tgt" >&2
        layer_c_ok=false
      fi
      if ! echo "$managed_block" | grep -qF "\"$url\""; then
        echo "FAIL: Package.swift managed block missing url $url for $tgt" >&2
        layer_c_ok=false
      fi
      if ! echo "$managed_block" | grep -qF "\"$tgt\""; then
        echo "FAIL: Package.swift managed block missing target name $tgt" >&2
        layer_c_ok=false
      fi
      if ! [[ "$sha" =~ ^[0-9a-f]{64}$ ]]; then
        echo "FAIL: manifest sha for $tgt is not 64-hex: $sha" >&2
        layer_c_ok=false
      fi
    done < <(jq -r '.xcframeworks[] | [.swift_target_name, .zip_sha256, .release_asset_url] | @tsv' "$MANIFEST")

    if [ "$layer_c_ok" = true ]; then
      echo "  PASS: all $xcf_count xcframework checksums + urls + target names present in managed block"
    else
      ERRORS=$((ERRORS + 1))
    fi
  fi
fi

# =============================================================================
# Layer A: fresh-checkout swift build
# =============================================================================
echo ""
echo "==> Layer A: fresh-checkout swift build"
echo "  Mode: $([ "$URL_MODE" = true ] && echo 'URL-mode (post-release)' || echo 'path-mode (local dev)')"
echo "  NOTE: URL-mode (--url-mode flag) tests against a published GitHub Release."
echo "        Path-mode tests the module builds correctly from a local consumer."

if [ "$SKIP_LAYER_A" = true ]; then
  echo "  SKIP: --skip-layer-a requested"
else
  TMPDIR_A=$(mktemp -d)
  trap "rm -rf $TMPDIR_A" EXIT

  cd "$TMPDIR_A"
  mkdir consumer && cd consumer

  if [ "$URL_MODE" = true ]; then
    if [ ! -f "$MANIFEST" ]; then
      echo "FAIL: --url-mode requires rewrap-manifest.json (run from repo root)" >&2
      ERRORS=$((ERRORS + 1))
    else
      RELEASE_TAG=$(jq -r .tag "$MANIFEST")
      cat > Package.swift <<PKG_EOF
// swift-tools-version:5.9
import PackageDescription
let package = Package(
  name: "Consumer",
  platforms: [.iOS(.v17), .macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/helenkwok/LiteRTLM-Swift", revision: "$RELEASE_TAG")
  ],
  targets: [
    .target(
      name: "Consumer",
      dependencies: [.product(name: "LiteRTLMSwift", package: "LiteRTLM-Swift")]
    )
  ]
)
PKG_EOF
    fi
  else
    cat > Package.swift <<PKG_EOF
// swift-tools-version:5.9
import PackageDescription
let package = Package(
  name: "Consumer",
  platforms: [.iOS(.v17), .macOS(.v14)],
  dependencies: [
    .package(path: "$REPO_ROOT")
  ],
  targets: [
    .target(
      name: "Consumer",
      dependencies: [.product(name: "LiteRTLMSwift", package: "LiteRTLM-Swift-fork")]
    )
  ]
)
PKG_EOF
  fi

  mkdir -p Sources/Consumer
  cat > Sources/Consumer/main.swift <<'SWIFT_EOF'
import LiteRTLMSwift
// Verify RewrapManifest compiles and is accessible
let tag = RewrapManifest.tag
let entries = RewrapManifest.entries
print("LiteRTLMSwift module OK — tag: \(tag), entries: \(entries.count)")
SWIFT_EOF

  set +e
  IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
  if [ -n "$IOS_SDK" ]; then
    swift build --triple arm64-apple-ios17.0 -Xswiftc -sdk -Xswiftc "$IOS_SDK" 2>&1
  else
    echo "FAIL: unable to resolve iPhoneOS SDK via xcrun" >&2
    false
  fi
  LAYER_A_EXIT=$?
  set -e

  cd "$REPO_ROOT"

  if [ "$LAYER_A_EXIT" -ne 0 ]; then
    echo "FAIL: fresh-checkout swift build exited $LAYER_A_EXIT" >&2
    ERRORS=$((ERRORS + 1))
  else
    echo "  PASS: fresh-checkout swift build succeeded"
  fi
fi

# =============================================================================
# Final result
# =============================================================================
echo ""
if [ "$ERRORS" -eq 0 ]; then
  if [ "$SKIP_LAYER_A" = true ]; then
    echo "==> REQUESTED LAYERS PASSED (B + C; Layer A skipped)"
  else
    echo "==> ALL LAYERS PASSED (A + B + C)"
  fi
  exit 0
else
  echo "==> FAILED: $ERRORS layer(s) failed" >&2
  exit 1
fi
