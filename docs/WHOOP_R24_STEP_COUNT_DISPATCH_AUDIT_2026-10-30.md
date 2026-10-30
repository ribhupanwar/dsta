# WHOOP R24 step-count dispatch audit

Date: 2026-10-30  
Source IPA SHA-256: `8a5deedc59567612683feb77dd7348238de89437123946b3344bc6ff1e90af8a`  
Mach-O SHA-256: `04013f93864e8a083b683d8d4d3e88728dec01d6b8d6c61c34df0d41f5df47b7`

## Verified static-disassembly observations

1. The original WHOOP ARM64 binary contains the strings:
   - `Historical Processed Steps Packet (R24)`
   - `Processed Steps Data (R24)`
   - `HealthKitStepCountRequest`
   - `HealthKitStepCountSubmissionDTO`
   - `step_count_samples`
   - `currentStepCount`, `lastStepCount`, and `previousStepCount`
   - IMU packet parser types and detailed IMU parse errors.

2. Historical packet enum dispatch at `0x105ce7fdc–0x105ce7ff4` masks the selector to one byte, indexes a 256-byte table at `0x108ebdb70`, and branches through a relative jump table. In this extracted table, selector values 9 and 68 select the branch at `0x105ce8038`.

3. That branch constructs the enum case named `Historical Processed Steps Packet (R24)`. Its returned enum discriminator is built from the Swift enum base plus case index `0x12`. This is strong evidence that the historical packet enum has a dedicated R24 case; it does **not** reveal the payload's field layout.

4. A second packet-type dispatcher at `0x100802720–0x100802738` indexes table `0x108acfdee`. The branch at `0x100802748` constructs `Processed Steps Data (R24)`. The extracted table's candidate selector-byte values for this branch are 11, 28, 92, 94, 148, 200, and 202. Treat these as static table observations pending validation of the input byte's semantic role and call path.

5. The WHOOP binary also contains a HealthKit step-count request/submission path and Core Data-style step sample keys. Therefore, the Type-47 v18 motion counter should not be assumed to be the sole source of the app's displayed daily step total.

## Implications for PulseForge

- Keep the Type-47 v18 counter decoder marked experimental. Its two UInt16 candidate counters and cadence/activity bytes have not yet been proven to represent user-visible steps.
- Prioritize tracing the historical R24 enum case from its dispatch site into the concrete payload decoder/model, then identify the fields used to create `step_count_samples` and update `currentStepCount`.
- Separately trace the processed-data R24 dispatch at `0x100802748` to determine whether it is a payload model, an event type, or an intermediate data wrapper.
- Correlate any decoded count/timestamp against a controlled walk and WHOOP's displayed count before promoting it to trusted daily steps.
- Do not merge motion-counter deltas into a daily total until counter units, reset behavior, time attribution, and midnight handling are validated.

## Limitations

This is static ARM64 disassembly and string/xref evidence from the supplied WHOOP IPA. It does not prove runtime BLE transport, packet framing, checksums, payload offsets, count units, or which path updates the UI. No packet was modified or transmitted. The extracted audit ZIP contains reference-site context but the current audit does not yet establish the R24 payload schema.
