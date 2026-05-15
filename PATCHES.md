# PATCHES.md

Running log of divergence between `helenkwok/LiteRTLM-Swift` and upstream `mylovelycodes/LiteRTLM-Swift`.

Re-sync cadence: quarterly diff against `upstream/main`.

---

## 2026-05-15 — Add `scripts/rewrap-xcframework.sh` (resolves upstream issue #6)

Adds a deterministic re-wrap recipe for `LiteRTLM.xcframework` so the artifact passes App Store / TestFlight notary. Three fixes addressed offline:

- **Info.plist key:** Injects `CFBundleShortVersionString` + `CFBundleVersion` (default `0.1.0` / `1`, env-var overridable via `LITERTLM_VERSION` / `LITERTLM_BUILD`) into every `CLiteRTLM.framework/Info.plist`.
- **Loose dylib split:** Promotes `libGemmaModelConstraintProvider.dylib` to its own `GemmaModelConstraintProvider.framework` peer with synthesized `Info.plist`, `install_name_tool -id @rpath/...`, and ad-hoc `codesign`.
- **dSYM emission:** Runs `dsymutil` on both binaries and threads the resulting `.dSYM` bundles through `xcodebuild -create-xcframework -debug-symbols`.

Output: `LiteRTLM-rewrapped.xcframework` (sibling of input — debug-friendly, easy to revert vs in-place rewrite).

Validated by: `scripts/test-rewrap-output.sh` (offline checks per RESEARCH.md Q4) — exercised end-to-end against the shipped `Frameworks/LiteRTLM.xcframework`; both slices (`ios-arm64`, `ios-arm64-simulator`) pass all three checks. Full TestFlight validation deferred to v1.2 per offlineaid CONTEXT D-25.

### Deviation from offlineaid Phase 14 RESEARCH.md Q4

The recipe in RESEARCH.md Q4 emitted a single `LiteRTLM-rewrapped.xcframework` containing both `CLiteRTLM.framework` and the promoted `GemmaModelConstraintProvider.framework` as peer entries per slice. `xcodebuild -create-xcframework` rejects this with `A library with the identifier 'ios-arm64' already exists` — it allows only one framework per platform identifier.

Resolved by emitting two sibling xcframeworks: `LiteRTLM-rewrapped.xcframework` (CLiteRTLM only) and `GemmaModelConstraintProvider.xcframework` (single-slice — GMCP currently ships only in `ios-arm64`). Consumers must embed both peers. Plan 14-02 (vendor + podspec) needs to wire both into `expo-litert-lm/ios/Frameworks/`.
