# WHOOP 5.75.0 RR / historical packet evidence

## Scope and provenance

This note records static evidence collected from the user-provided WHOOP IPA release:

- App: WHOOP 5.75.0 (build 738478)
- Bundle identifier: `com.whoop.iphone`
- IPA SHA-256: `8a5deedc59567612683feb77dd7348238de89437123946b3344bc6ff1e90af8a`
- Executable: `Payload/Whoop.app/Whoop`
- Executable format: 64-bit ARM64 Mach-O
- Minimum iOS: 18.0
- SDK recorded in Mach-O: 27.0
- `LC_ENCRYPTION_INFO_64`: `cryptid 0` (the inspected executable reports no active Mach-O encryption flag)

The audit used public archive metadata, symbol names, and strings. It did not patch, decrypt, or bypass app protections.

## RR / timestamp-related evidence found

The executable contains these relevant Swift symbol or metadata strings:

- `WhoopStrapServices.RealtimeHeartRateData` protocol
- `WhoopPacket.HistoricalSequenceable` protocol
- `rrIntervalsCount: UInt8`
- `rrIntervalsPadding: [UInt16]`
- `RRIntervalsCountFailedToParse`
- `RRIntervalsFailedToParse`
- `RRIntervalsPaddingBytesNotAllZeroes`
- A heart-rate data initializer whose demangled signature includes:
  - `heartRate`
  - `rrIntervals`
  - `onOffStatus`
  - `bodyLocation`
  - `EpochWith16BitSubseconds`
  - `UInt8`
  - `[UInt16]`
- A related initializer containing `heartRate`, `rrIntervals`, `EpochWith16BitSubseconds`, and `[UInt16]`
- Packet metadata initializer fields including `flags`, `timestamp`, `sequence`, `dataCycle`, `packetType`, and `packetTypeRevision`
- `timestampsUnixNano: [UInt64]`
- `timestampEpoch` and `r10TimestampSubSecondsOffset`

These findings strengthen the evidence that WHOOP's data model has explicit RR interval collections and a timestamp abstraction with 16-bit subseconds. They are useful for guiding capture analysis and model design.

## What this audit does NOT prove

Static symbol names and initializer signatures do not disclose a complete wire-format specification. They do not establish:

- The byte offsets of fields in type-40 or type-47 BLE frames
- Whether a particular offset is relative to the BLE payload, packet header, or decoded body
- Byte order and interval units for each packet revision
- The exact mapping between packet type, revision, and physiological record kind
- The epoch, subsecond scale, rollover, or timezone conversion for `EpochWith16BitSubseconds`
- That the current NOOP-derived candidate offsets match a physical WHOOP 5.0 capture

Do not infer the timestamp from phone receipt time. Keep `physiologicalTimestamp` nil until a captured frame can be decoded and independently correlated.

## PulseForge implementation guardrails

- Preserve every CRC-valid type-47 v18 raw frame before attempting candidate RR decoding.
- Retain raw hex and the candidate decode error when decoding is rejected.
- Keep phone `receivedAt` distinct from physiological sample time.
- Treat the current type-40 and type-47 offsets as NOOP-fixture-derived candidates, not confirmed WHOOP layouts.
- Do not feed candidate historical RR or short-window realtime RMSSD into overnight HRV, Sleep, or Recovery until packet semantics and physiological timestamps are validated.
- Require physical WHOOP 5.0 captures with known context to validate the layout and timestamp independently.

## Build verification associated with this evidence

- Main source commit inspected: `e4f27f765947158e3b87e4ebb36955c18ce30cc8`
- Simulator CI run: `40876292272` — successful; 69 tests passed in its test log.
- Unsigned device archive export verification: `40877733479` — successful on a verification branch based on the main source commit. Artifact is unsigned and must be signed by SideStore/AltStore before installation.
- The earlier CI failure at `a7f9d947` was caused by passing `decodeError` to a memberwise initializer whose stored property had a default value. The current main version declares both optional fields without stored-property defaults and passes explicit `nil` values where appropriate.

This note is an evidence ledger, not a claim that the WHOOP BLE wire layout or physiological timestamp has been reverse-engineered.


## Current PulseForge score inputs (important distinction)

On the inspected main source revision, the existing Recovery estimate reads Apple Health HRV SDNN and resting-heart-rate samples, then applies PulseForge's own HRV/RHR weighting and baseline logic. It is explicitly labelled as an Apple Health SDNN estimate, not WHOOP RMSSD. Sleep duration and sleep-debt inputs currently come from HealthKit sleep-analysis samples. These are useful provisional app features, but they are not a reconstruction of WHOOP's proprietary overnight pipeline.

Do not relabel these scores as WHOOP-derived merely because WHOOP may write samples into Apple Health. Source attribution must be checked per sample before making that claim.
