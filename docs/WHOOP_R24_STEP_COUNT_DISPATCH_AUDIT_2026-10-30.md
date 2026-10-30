# WHOOP R24 step-count dispatch audit

Date: 2026-10-30  
Source IPA SHA-256: `8a5deedc59567612683feb77dd7348238de89437123946b3344bc6ff1e90af8a`  
Mach-O SHA-256: `04013f93864e8a083b683d8d4d3e88728dec01d6b8d6c61c34df0d41f5df47b7`

## Verified static-disassembly observations

1. The original WHOOP ARM64 binary contains:
   - `Historical Processed Steps Packet (R24)`
   - `Processed Steps Data (R24)`
   - `HealthKitStepCountRequest` and `HealthKitStepCountSubmissionDTO`
   - `step_count_samples` and `deleted_step_count_samples`
   - `currentStepCount`, `lastStepCount`, `previousStepCount`
   - IMU packet parser types and detailed IMU parse errors.

2. Historical packet enum dispatcher at `0x105ce7fdc–0x105ce7ff4` masks its input to one byte, indexes a 256-byte table at `0x108ebdb70`, then branches through relative offsets. Table bytes at selector indexes **9 and 68** select branch `0x105ce8038`, which constructs the Swift enum case named `Historical Processed Steps Packet (R24)` (enum case index 0x12). This is strong evidence of a dedicated historical R24 packet enum case. The selector's exact wire-field meaning and R24 payload layout remain unproven.

3. A separate dispatcher at `0x100802720–0x100802738` begins by constructing the label `IMU Data`, masks its input to one byte, and indexes table `0x108acfdee`. Its branch at `0x100802748` returns the associated type label `Processed Steps Data (R24)` and a Swift enum case value. The raw table contains candidate indexes 11, 28, 92, 94, 148, 200, and 202. This is an IMU-data subtype/factory path, not proof that these indexes are step counts or packet IDs. Earlier wording that called it a generic packet-type dispatcher was too strong.

4. At `0x10036dcb4`, WHOOP references the Core Data entity/key `step_count_samples`. Immediately upstream, the same function references Apple's `HKQuantityTypeIdentifierStepCount`; immediately downstream it passes the literal key `step_count` into a model/record processing call at `0x10036e4a4`. A parallel block references `deleted_step_count_samples`. This is a concrete data-ingestion/storage path for step samples, but the sample's numeric value and timestamp fields have not yet been recovered from this context alone. A follow-up workflow now extracts the exact disassembly window around `0x10036e4a4`, the ingestion callsite, and references to `currentStepCount` / `lastStepCount` / `previousStepCount` / `delayedStepCountProcessingWorkItem`.

5. OpenStrap's public protocol documentation describes a general 1 Hz historical R24 record, but separately lists WHOOP 5 Gen5 historical record decoders as v18/v20/v21/v22/v26. Do not transplant a Gen4/general R24 byte layout into this WHOOP 5.0 v18 capture without direct parity evidence. [OpenStrap protocol README](https://github.com/OpenStrap/protocol)

## Implications for PulseForge

- Keep Type-47 v18 counter decoding experimental. The candidate UInt16 fields have not been proven to represent user-visible steps.
- Trace the historical R24 enum case's consumers and the concrete payload parser/model; identify how it yields sample timestamp and count.
- Decode the new exact disassembly windows around `0x10036e4a4` and the step-count state accessors; identify numeric value, timestamp, units, and update/merge semantics.
- Determine whether official WHOOP step samples are derived from the R24 historical case, HealthKit import, or both.
- Correlate decoded count/timestamp against a controlled walk and the official WHOOP displayed count before promoting any source to trusted daily steps.

## Limitations

This is static ARM64 disassembly and string/xref evidence from the supplied WHOOP IPA. It does not prove runtime BLE transport, packet framing, checksums, payload offsets, count units, or which path updates the UI. No packet was modified or transmitted. No R24 payload schema has yet been established.
