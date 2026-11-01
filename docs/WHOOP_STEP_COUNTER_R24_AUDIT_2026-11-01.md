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

A separate enum type-label/string builder at `0x1008026fc` is also present. Its disassembly constructs an `IMU Data` label and uses a second switch table at `0x108acfdee`; that table has seven inputs (11, 28, 92, 94, 148, 200, 202) selecting the `Processed Steps Data (R24)` label branch. This is a display/type-description path, **not evidence of a byte-level packet decoder**.

The label builder has five recorded call sites:

- `0x100249088` from `0x100248774`
- `0x100a4e210` from `0x100a4deb4`
- `0x105d03434` from `0x105ce95dc`
- `0x105d03dec` from `0x105d03cac`
- `0x105d04018` from `0x105ce95dc`

The call at `0x105d03dec` is inside the recovered `0x105d03cac` caller. These xrefs help locate the R24 type-description path but must not be mistaken for parser xrefs. The actual field decoder behind the historical packet dispatch at `0x105ce8038` remains to be recovered.

## Separate step-sample ingestion path

The audit also identifies a distinct path around `0x10036dcb4`:

- It constructs the key string `step_count`.
- It calls `0x10036e4a4` to process the associated model value.
- Nearby functions parse related time fields and iterate sample/model objects.

This is evidence of a step-sample ingestion/model path, but it is not enough to identify a WHOOP strap BLE packet layout. Do not treat this JSON/model key as an R24 payload offset.

The binary contains `HealthKitStepCountRequest` and `HealthKitStepCountSubmissionDTO` strings, but the audit's direct-xref reports for both are empty. The step-count state-accessor scan also returned zero matching instruction/string lines. Those are unresolved, not proof that the state is absent.

## Existing PulseForge implementation caution

The older `whoop-background-ble` branch contains `Gen5R18StepCounter.swift`, but the current `ui/whoop-native-shell-v1` branch does not. The R18 decoder reads candidate offsets 57/59/61/63/64. Its XCTest fixture is entirely synthetic: it creates a zero-filled 124-byte frame, writes the expected type/revision and candidate values, then calculates and writes the CRC itself. No captured WHOOP frame is used, so those tests prove only that the implementation agrees with its own fixture.

There is also a CRC-comment issue in that candidate: for a 124-byte format-1 frame, bytes 120–123 are the same footer used by the transport-envelope CRC check. The decoder's second CRC calculation is therefore not an independent record CRC as its comment claims. The current UI branch's Type-47 revision-18 handler is primarily an unverified RR candidate path. The R18 offsets have not been tied to the R24 symbols above or proven against a live step-bearing capture.

Do **not** transplant the R18 candidate decoder into the current UI branch or label its selected counter as daily steps until its source fields and semantics are proven. Keep raw frames and diagnostic evidence separate from user-visible step totals.

## PulseForge capture instrumentation added

The current UI branch now archives CRC-valid Type-47 frames that reach the unclassified-revision fallback without decoding them:

- Source: `PulseForge/HistoricalWhoopPacketArchive.swift`
- Integration: `PulseForge/WhoopBluetoothManager.swift`, Type-47 fallback
- App Support archive: `PulseForge/historical-whoop-type47-v1.json`
- Retention: newest 500 records on disk; latest 40 frames are included in the in-memory diagnostic snapshot
- Stored fields: receipt time, GATT channel, packet type, revision byte, byte count, outer transport-CRC validation, complete raw frame hex, and an explicit raw-only classification

R18 and R21 continue through their existing separate paths. This new archive targets unknown revisions such as the R24 candidate. It intentionally does not call any field decoder or create a step total. The purpose is to obtain real, CRC-valid frames for byte-for-byte correlation with the WHOOP IPA dispatcher. The app's diagnostics panel exposes `diagnosticSnapshot` through its `EXPORT` ShareLink; export it after the WHOOP history sync while the app is still connected. The snapshot includes the most recent unclassified Type-47 raw frames and their channel/revision/length metadata.

## Next engineering sequence

1. Trace the historical dispatcher entry at `0x105ce7ff8` and the R24 branch at `0x105ce8038`; identify the exact discriminator byte and record-reader entry.
2. Follow the R24 branch through its callees until the byte reader / field accessors are identified. Recover length checks, offsets, integer widths, endianness, units, and any counter-reset/rollover handling.
3. Compare those offsets against CRC-valid Type-47 frames already captured from the user's WHOOP 5.0. Preserve the raw hex, channel, frame length, revision, sequence, and capture timestamp.
4. Only after a match, implement an isolated R24 decoder with fixture-based tests. Keep it diagnostic until repeated device captures prove it is the same step metric the official app displays.
5. Separately trace the `step_count` model ingestion path to determine whether it is server/API data, HealthKit submission, or a derived sample pipeline; do not conflate it with the BLE decoder.

## Build/CI note

The iOS CI font-extraction step was incorrectly searching an iOS WHOOP archive for Android-style `res/font/*.ttf` / `*.otf` paths. That assumption produced the #610 failure before Xcode project discovery/build. The step has been replaced with an optional bundled-font check so CI can proceed without misclassifying the IPA archive.


## Follow-up Mach-O audit run #42 — 2026-11-01 15:06 UTC

A fresh targeted audit artifact was generated from the same pinned WHOOP 5.75.0 binary (whoop-ipa-mach-o-protocol-audit, workflow run #42). It confirms the distinction between the R24 enum/type label and a parser:

- At 0x105ce7fb8, the historical packet classifier masks its input to one byte (and x8, x0, #0xff), indexes the lookup table at 0x108ebdb70 with ldrb, and branches through the selected target. The R24 branch at 0x105ce8038 returns the R24 enum case and the string label. This identifies a one-byte classifier input, but does not prove which byte of the transport frame supplies it.
- At 0x100802720, a separate IMU-data type-label builder masks its input to one byte and indexes the table at 0x108acfdee. Its R24 case returns the label and enum value. This remains metadata/type-description logic, not the R24 field reader.
- The second xref at 0x105cf6378 is a collection of known historical packet type labels used by an analytics/model path. It is not a byte-level decode routine.
- The step_count model ingestion code around 0x10036dcb4 was traced further. Its associated processing function at 0x10036e4a4 references the HealthKit symbol _HKQuantityTypeIdentifierStepCount at 0x10036ea68, alongside other HealthKit quantity types. This supports treating that path as a HealthKit-backed sample/model ingestion path; it does not establish that the R24 BLE packet is decoded there.

**Result:** the latest static audit narrows the R24 discriminator to a one-byte argument passed into a lookup-table classifier, but still does not identify the transport-frame offset or the R24 record reader. No trustworthy R24 counter offset, integer width, endianness, unit, or reset semantics has been recovered. The native WHOOP step counter is therefore still **not cracked**. The raw Type-47 capture archive remains the required bridge between static disassembly and actual band traffic.

Artifact provenance: GitHub Actions run #42, commit 53dbd8e15671b29aa50b9ac2f14fab8d938136fa, artifact whoop-ipa-mach-o-protocol-audit.
