# Release Runbook — LiteRTLM-Swift-fork

This document describes how to cut a release of the rewrapped LiteRTLM xcframeworks.
A release publishes two xcframework zips + `rewrap-manifest.json` as GitHub Release assets,
which downstream consumers (expo-litert-lm, direct SPM consumers) can fetch and verify.

---

## Tag naming convention

Tags follow the pattern `<upstream-version>+rewrap.<iteration>`:

| Tag | Meaning |
|-----|---------|
| `v0.7.3+rewrap.1` | First rewrap of upstream LiteRT-LM v0.7.3 |
| `v0.7.3+rewrap.2` | Re-cut of the same upstream (e.g. fix in rewrap script) |
| `v0.7.4+rewrap.1` | Rewrap of the next upstream version |

The `+` is a SemVer build-metadata separator (semver.org §10) — it does NOT affect
precedence, so SPM resolution is unambiguous. Git allows `+` in tag refs per
`git check-ref-format`. If SPM tooling ever rejects `+` in a binaryTarget URL,
the documented fallback is percent-encoding (`%2B`); the post-release URL-mode verify
step in CI would surface this immediately.

**Never reuse a `+rewrap.<n>` tag.** If you need to re-cut, always increment
`<iteration>` (e.g. `+rewrap.2`). This preserves the integrity of any existing
consumers pinned to the old tag.

---

## CI path (default)

1. Ensure `main` is up-to-date with all Task 1-5 changes.
2. Create and push the release tag:
   ```bash
   git tag v0.7.3+rewrap.1
   git push origin v0.7.3+rewrap.1
   ```
3. Open https://github.com/helenkwok/LiteRTLM-Swift/actions and confirm the
   `release` workflow runs to green.
4. Verify the Release page at https://github.com/helenkwok/LiteRTLM-Swift/releases/tag/v0.7.3+rewrap.1
   contains all three assets (see Post-release verification below).

---

## Escape valve (D-37) — if CI is stuck > 1 day

Use this if:
- macOS runner hours are exhausted
- Xcode pinning blocks the workflow
- GitHub Actions is unavailable

Steps (produces byte-identical output to CI):

```bash
# 1. From the repo root, run the escape valve make target
git tag v0.7.3+rewrap.1
make release TAG=v0.7.3+rewrap.1
```

`make release TAG=...` does the following:
1. Runs `scripts/rewrap-xcframework.sh --tag <tag>` — produces both xcframework zips + rewrap-manifest.json
2. Runs `make verify` (all three Layer A/B/C gates)
3. Runs `gh release create <tag> ... <zip files> rewrap-manifest.json`

Requires `gh` CLI authenticated as a maintainer: `gh auth login` if not already.

---

## Post-release verification checklist

After any release (CI or escape valve), verify:

- [ ] Release URL is accessible: `gh release view v0.7.3+rewrap.1 --repo helenkwok/LiteRTLM-Swift`
- [ ] Both xcframework zips listed: `gh release view v0.7.3+rewrap.1 --repo helenkwok/LiteRTLM-Swift --json assets --jq '.assets[].name'`
  - Must include: `LiteRTLM-rewrapped-v0.7.3+rewrap.1.xcframework.zip`
  - Must include: `GemmaModelConstraintProvider-v0.7.3+rewrap.1.xcframework.zip`
  - Must include: `rewrap-manifest.json`
- [ ] Manifest is valid:
  ```bash
  gh release download v0.7.3+rewrap.1 --repo helenkwok/LiteRTLM-Swift --pattern 'rewrap-manifest.json' -D /tmp/verify-rel
  jq . /tmp/verify-rel/rewrap-manifest.json  # should show schema_version: 1
  jq '.xcframeworks | length' /tmp/verify-rel/rewrap-manifest.json  # should be 2
  ```
- [ ] SHA-256 of downloaded LiteRTLM zip matches manifest:
  ```bash
  gh release download v0.7.3+rewrap.1 --repo helenkwok/LiteRTLM-Swift --pattern '*.zip' -D /tmp/verify-rel
  expected=$(jq -r '.xcframeworks[0].zip_sha256' /tmp/verify-rel/rewrap-manifest.json)
  actual=$(shasum -a 256 /tmp/verify-rel/LiteRTLM-rewrapped-v0.7.3+rewrap.1.xcframework.zip | awk '{print $1}')
  [ "$actual" = "$expected" ] && echo "SHA OK" || echo "SHA MISMATCH"
  ```
- [ ] Fresh-checkout `swift build` succeeds:
  ```bash
  cd /tmp && mkdir spm-smoke && cd spm-smoke
  cat > Package.swift <<'EOF'
  // swift-tools-version:5.9
  import PackageDescription
  let package = Package(
    name: "Smoke",
    platforms: [.iOS(.v17)],
    dependencies: [.package(url: "https://github.com/helenkwok/LiteRTLM-Swift", exact: "v0.7.3+rewrap.1")],
    targets: [.target(name: "Smoke", dependencies: [.product(name: "LiteRTLMSwift", package: "LiteRTLM-Swift-fork")])]
  )
  EOF
  mkdir -p Sources/Smoke && echo 'import LiteRTLMSwift; print(RewrapManifest.tag)' > Sources/Smoke/main.swift
  swift build
  ```

---

## Rollback procedure

If a release needs to be yanked:

```bash
# 1. Delete the GitHub Release (assets are also deleted)
gh release delete v0.7.3+rewrap.1 --repo helenkwok/LiteRTLM-Swift --yes

# 2. Delete the tag remotely
git push origin :refs/tags/v0.7.3+rewrap.1

# 3. Delete the tag locally
git tag -d v0.7.3+rewrap.1

# 4. Re-cut with the next iteration (NEVER reuse v0.7.3+rewrap.1)
git tag v0.7.3+rewrap.2
git push origin v0.7.3+rewrap.2
# OR: make release TAG=v0.7.3+rewrap.2
```

---

## Branch protection note

`main` is branch-protected: only PRs that pass the `verify-consumption / verify`
status check can merge. This is the supply-chain trust anchor for the
`binaryTarget(url:, checksum:)` pattern — if anyone could push directly to main,
they could substitute a malicious checksum + URL in Package.swift without the
manifest-managed seam being exercised. See threat model T-14-17 in the plan.

Tag pushes matching `v*+rewrap.*` are also protected (GitHub Settings → Tags).
Only maintainer accounts can push matching tags, which limits who can trigger
the release workflow.
