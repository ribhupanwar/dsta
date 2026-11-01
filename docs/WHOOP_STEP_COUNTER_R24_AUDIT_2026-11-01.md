# WHOOP Step Counter Reverse-Engineering Audit — 2026-11-01

## Scope and provenance

This note records static findings from the existing `whoop-ipa-mach-o-protocol-audit.zip` for WHOOP 5.75.0 (build 738478).

- IPA SHA-256: `8a5deedc59567612683feb77dd7348238de89437123946b3344bc6ff1e90af8a`
- Mach-O binary SHA-256: `04013f93864e8a083b683d8d4d3e88728dec01d6b8d6c61c34df0d41f5df47b7`
- Architecture: arm64

All findings below are static binary evidence. They do not prove the live BLE subscription, packet contents, or runtime path. No parser offsets should be shipped until they match actual CRC-valid WHOOP captures.

## Strongest current lead: Historical Processed Steps Packet (R24)

The binary contains two directly relevant type/model strings:

- `Historical Processed Steps Packet (R24)` at Mach-O virtual address `0x109218970`.
- `Processed Steps Data (R24)` at `0x1090d5e10`.

The historical packet enum switch table at `0x108ebdb70` has an R24 branch target at `0x105ce8038` (dispatcher branch site `0x105ce7ff8`). The recovered lookup-table analysis identifies table input indexes **9** and **68** as selecting that branch. The field supplying the lookup index and its exact relationship to the on-wire frame still need confirmation.

A related factory at `0x1008026fc` has five recorded call sites:

- `0x100249088` from `0x100248774`
- `0x100a4e210` from `0x100a4deb4`
- `0x105d03434` from `0x105ce95dc`
- `0x105d03dec` from `0x105d03cac`
- `0x105d04018` from `0x105ce95dc`

The call at `0x105d03dec` is inside the recovered `0x105d03cac` caller. This establishes a concrete R24-related factory/caller chain to investigate; it does not yet reveal the packet's field offsets or step-count units.

## Separate step-sample ingestion path

The audit also identifies a distinct path around `0x10036dcb4`:

- It constructs the key string `step_count`.
- It calls `0x10036e4a4` to process the associated model value.
- Nearby functions parse related time fields and iterate sample/model objects.

This is evidence of a step-sample ingestion/model path, but it is not enough to identify a WHOOP strap BLE packet layout. Do not treat this JSON/model key as an R24 payload offset.

The binary contains `HealthKitStepCountRequest` and `HealthKitStepCountSubmissionDTO` strings, but the audit's direct-xref reports for both are empty. The step-count state-accessor scan also returned zero matching instruction/string lines. Those are unresolved, not proof that the state is absent.

## Existing PulseForge implementation caution

The older `whoop-background-ble` branch contains `Gen5R18StepCounter.swift`, but the current `ui/whoop-native-shell-v1` branch does not. The current UI branch's Type-47 revision-18 handler is primarily an unverified RR candidate path. The R18 candidate offsets have not been tied to the R24 symbols above or proven against a live step-bearing capture.

Do **not** transplant the R18 candidate decoder into the current UI branch or label its selected counter as daily steps until its source fields and semantics are proven. Keep raw frames and diagnostic evidence separate from user-visible step totals.

## Next engineering sequence

1. Trace the historical dispatcher entry at `0x105ce7ff8` and the R24 branch at `0x105ce8038`; identify the exact discriminator byte and record-reader entry.
2. Follow the R24 branch through its callees until the byte reader / field accessors are identified. Recover length checks, offsets, integer widths, endianness, units, and any counter-reset/rollover handling.
3. Compare those offsets against CRC-valid Type-47 frames already captured from the user's WHOOP 5.0. Preserve the raw hex, channel, frame length, revision, sequence, and capture timestamp.
4. Only after a match, implement an isolated R24 decoder with fixture-based tests. Keep it diagnostic until repeated device captures prove it is the same step metric the official app displays.
5. Separately trace the `step_count` model ingestion path to determine whether it is server/API data, HealthKit submission, or a derived sample pipeline; do not conflate it with the BLE decoder.

## Build/CI note

The iOS CI font-extraction step was incorrectly searching an iOS WHOOP archive for Android-style `res/font/*.ttf` / `*.otf` paths. That assumption produced the #610 failure before Xcode project discovery/build. The step has been replaced with an optional bundled-font check so CI can proceed without misclassifying the IPA archive.
