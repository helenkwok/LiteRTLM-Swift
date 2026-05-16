#!/usr/bin/env bash
# generate-package-manifest.sh
# Thin wrapper that calls rewrap-xcframework.sh --regenerate-only.
# Re-emits rewrap-manifest.json + Sources/LiteRTLMSwift/RewrapManifest.swift +
# Package.swift MANIFEST-MANAGED block from existing rewrapped xcframeworks
# on disk — without redoing the actual xcodebuild rewrap work.
#
# Used by verify-consumption.sh Layer C for fast drift detection.
# Usage: ./scripts/generate-package-manifest.sh [--tag <tag>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

exec "$SCRIPT_DIR/rewrap-xcframework.sh" --regenerate-only "$@"
