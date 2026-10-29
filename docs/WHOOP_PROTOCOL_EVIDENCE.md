# WHOOP 5.75.0 protocol evidence audit

Date: 2026-10-29

## Primary source inspected

- Release asset: `whoop-5.75.0/pulseforge.ipa`
- App identity: `com.whoop.iphone`, version `5.75.0`, build `738478`
- IPA SHA-256: `8a5deedc59567612683feb77dd7348238de89437123946b3344bc6ff1e90af8a`
- Static extraction workflow: [WHOOP IPA protocol resource inspection](https://github.com/ribhupanwar/dsta/actions/runs/40841844863)
- Evidence artifact: [whoop-ipa-protocol-byte-evidence](https://github.com/ribhupanwar/dsta/actions/runs/40841844863/artifacts/12883311134)

## Observed in the original IPA

### Hello resources

The app bundle contains two resources:

| Resource | Size | SHA-256 |
|---|---:|---|
| `HelloPacketRev3` | 144 bytes | `5d152eb178c554f0674c1d0fe279f15fb339d054f7bbbb5b8b14fd0ebb2d7105` |
| `HelloPacketRev4` | 144 bytes | `50d0c6c9c774ee4c91e6cba369eb70d10d061824305fc045283dcfdb6152e984` |

The raw resource bytes were extracted into the workflow artifact for local analysis. Their internal fields have **not** yet been decoded or mapped to PulseForge's 16-byte `CLIENT_HELLO` write. Resource names alone do not prove whether they are outbound hello payloads, response templates, or another revision-specific representation.

### Executable symbols and strings

The WHOOP executable contains these demangled Swift protocol abstractions:

- `WhoopPacket.FrameEnvelopePacket`
- `WhoopPacket.HelloResponsePacket`
- `WhoopPacket.WhoopPacketRevisionRouter`
- `WhoopPacket.RealtimeHRPacket`
- `WhoopPacket.RealtimeSequenceable`
- `WhoopPacket.HistoricalSequenceable`
- `WhoopPacket.HelloInfoProviding`
- `WhoopPacket.CRC`
- `WhoopStrapServices.RealtimeHeartRateData`
- `WhoopStrapServices.HistoricalPullServicing`

Additional executable strings include `RealtimeData`, `RealtimeDataType`, `RealtimeDataTypes`, `rrIntervals`, `rrIntervalsCount`, `rrIntervalsPadding`, `RRIntervalsCountTooLarge`, and `RRIntervalsPaddingBytesNotAllZeroes`. The symbol strings suggest an RR interval array and validation/padding handling, but do not by themselves prove the precise Type-40 or Type-47 field offsets.

### Connection and handshake log strings

The executable includes these diagnostic strings:

- `BLE - Characteristics Subscribed (Command Read, Data Read, Event Read) - Connection Manager current state:`
- `BLE - Characteristics Subscribed - Sending Hello Packet Command`
- `BLE - HELLO RESPONSE | Revision:`
- `Failed to get hello response`

**Observed ordering clue:** WHOOP's own diagnostic vocabulary places the Hello Packet command after the Command Read, Data Read and Event Read characteristics are subscribed, followed by a Hello Response revision. This is static string evidence, not a runtime trace; it does not establish exact callback ordering, characteristic UUID mapping, write bytes, or retry rules.

## PulseForge comparison

The current PulseForge manager:

- discovers GATT characteristics across discovered services;
- requests notifications for FD4B0003/0004/0005/0007;
- sends a 16-byte `CLIENT_HELLO` to FD4B0002 after characteristic discovery completes;
- re-arms vendor notifications after the CoreBluetooth write acknowledgement;
- parses Type-40 and Type-47 frames using the existing candidate layouts.

The WHOOP IPA evidence does **not** yet prove that these UUID-role mappings, the 16-byte hello payload, or this callback order match WHOOP's implementation. In particular, CoreBluetooth's write acknowledgement is not proof that the strap accepted the application-level hello response.

## Evidence grades and remaining gaps

| Claim | Grade | Confidence / limitation |
|---|---|---|
| Release is WHOOP iOS 5.75.0 build 738478 | **Observed** | High; Info.plist and archive identity |
| HelloPacketRev3/Rev4 resources are present and 144 bytes | **Observed** | High; extracted from the IPA |
| WHOOP executable has realtime and historical packet abstractions | **Observed** | High for symbol/string presence |
| WHOOP diagnostic text describes subscribing Command Read/Data Read/Event Read before sending Hello | **Observed** | High for string presence; runtime ordering remains unverified |
| RR data is represented by UInt16 interval values with count/padding validation | **Inferred** | Medium; symbol/type-name clues, no field-level parser mapping yet |
| PulseForge Type-40 offsets HR@16/count@17/RR@18 and Type-47 v18 offsets version@9/HR@22/count@23/RR@24 match WHOOP | **Not verified** | Current offsets came from NOOP captured fixtures; tests prove only those fixtures decode |
| PulseForge 16-byte CLIENT_HELLO and FD4B characteristic map match WHOOP's app | **Not verified** | Needs direct field/UUID mapping and device trace |
| BLE reconnect and handshake are reliable | **Not verified** | Requires repeatable WHOOP 5.0 device tests |

## Next protocol work

1. Map the two embedded HelloPacket resources and compare their revision-specific structure against the current PulseForge hello request/response handling.
2. Resolve WHOOP executable packet type and revision structures sufficiently to validate Type-40 and Type-47 field offsets; use NOOP/OpenStrap/OpenEdge only for gaps that the IPA cannot resolve.
3. Compare the resulting protocol model with captured WHOOP 5.0 frames and repeated connection traces.
4. Only then change packet/handshake behaviour. Keep live Type-40 RR/RMSSD separate from overnight HRV and sleep calculations; do not publish unverified Recovery, Sleep or Strain scores.

No protocol behaviour was changed by this evidence audit.


## Hello resource byte comparison (2026-10-29 follow-up)

A byte-for-byte comparison of the two extracted 144-byte resources found:

- Offset 9 changes from `0x03` to `0x04`, consistent with the resource revision names.
- Offsets 23–87 differ across a contiguous region. The bytes in this region include printable ASCII and a shifted NUL terminator; it is not a one-byte revision toggle.
- Additional differences occur at offsets 90–91, 94–95, 98–99, 102–103, 110–117, 122–124, 127–128, 131–132, and 135–136.
- The common 144-byte length and header prefix are observed; the differing regions are observed by direct byte comparison.

**Interpretation limit:** these offsets are byte-difference coordinates only. Without resolving the WHOOP executable's resource loader, packet serializer, and revision-specific field definitions, we cannot label these ranges as device ID, firmware, capabilities, CRC, or outbound command fields. Do not copy either blob into PulseForge or derive a CLIENT_HELLO from it yet.

**Next reverse-engineering step:** inspect the executable's references to `HelloPacketRev3` / `HelloPacketRev4`, `HelloInfoProviding`, and `HelloResponsePacket`; establish whether the resources are loaded as a request, template, or response-side structure, then map the serializer and response parser before changing BLE writes.


### Additional hello-related executable symbols

The extracted WHOOP executable string table also contains these names:

- `sendGetHelloPacket`
- `HelloSending` and `AsyncHelloSending`
- `HelloPacketMinSize` and `HelloPacketErrors`
- `HelloResponsePacket`, `HelloResponsePacketRev3`, `HelloResponsePacketRev4`, and `HelloResponsePacketRevRouter`
- `HelloInfoProviding` and `helloResponse`

These are **Observed** symbol/string names from the IPA executable. They establish that WHOOP has a distinct Hello sending path and revision-specific Hello Response parser/router abstractions. They do not expose the method bodies or prove that the two 144-byte bundle resources are the bytes written over BLE. In particular, the presence of both HelloPacketRev3/Rev4 resources and HelloResponsePacketRev3/Rev4 types makes it important not to conflate the request resource with the response parser.

PulseForge currently writes this 16-byte constant to FD4B0002:
`AA 01 08 00 00 01 E6 71 23 01 91 01 36 3E 5C 8D`.
That is **Observed in PulseForge source**, but its equivalence to WHOOP's `sendGetHelloPacket` request is **Not verified**. Do not replace it with either 144-byte resource without resolving the original sender implementation and response contract.


## Recovery / Sleep / Cardio Load verification audit (2026-10-29)

The following existing engines were re-read from `main`; they were not newly created in this protocol audit:

- `PulseForge/RecoveryScoreCalculator.swift`: transparent 0–100 estimate using Apple Health SDNN (60%) and resting HR (40%), with a median baseline requiring at least three prior daily values for both inputs. This is not WHOOP Recovery parity.
- `PulseForge/SleepNightCalculator.swift`: unions overlapping asleep intervals, joins fragments separated by up to 90 minutes without counting awake gaps as sleep, selects the longest session per wake day, and calculates debt from up to seven recorded nights.
- `PulseForge/SleepNeedCalculator.swift`: transparent heuristic with 8-hour default baseline, capped debt repayment, optional nap and strain adjustments. Personal baseline learning and calibrated strain adjustment are not wired into the current HealthKit store.
- `PulseForge/CardioLoadCalculator.swift`: timestamped workout-HR intensity × credited duration, deduplicated timestamps and 60-second gap cap. Explicitly not WHOOP's 0–21 Strain algorithm.
- `PulseForge/TrainingInsightsStore.swift`: reads HealthKit sleep, SDNN, resting HR, workouts and workout HR; withholds Recovery until today's HRV/RHR and three prior baseline days exist, and withholds cardio load without a measured max HR.

### CI evidence

Workflow run `40842102574` was labelled `cancelled` by the GitHub Actions job API, so its overall conclusion is not a clean successful workflow. However, its uploaded Xcode log artifact (`pulseforge-xcode-logs`, artifact `12883825768`) contains explicit `** BUILD SUCCEEDED **` and `** TEST SUCCEEDED **` markers. The test log reports **61 tests, 0 failures**, including:

- `RecoveryScoreCalculatorTests`: 4 passed
- `SleepNeedCalculatorTests`: 6 passed
- `SleepNightCalculatorTests`: 5 passed
- `CardioLoadCalculatorTests`: 4 passed

This verifies simulator compilation and these pure-calculation unit tests on that commit. It does not validate live HealthKit data, iPhone entitlements, real-device BLE, or WHOOP algorithm parity. The simulator test log also contains HealthKit entitlement errors (`Missing com.apple.developer.healthkit entitlement`), so HealthKit integration still requires a correctly signed iPhone build and explicit permission/data validation.

### Known validation gaps before publishing user-facing scores

1. Confirm HealthKit authorization and actual sample retrieval on the user's signed iPhone; simulator tests cannot establish this.
2. Confirm sleep stage/source de-duplication and night assignment against real Apple Health samples, including naps and timezone/day-boundary cases.
3. Strengthen Recovery input provenance and baseline quality; current score is an explicitly labelled PulseForge SDNN/RHR estimate, not overnight WHOOP RMSSD or WHOOP Recovery.
4. Keep Cardio Load separate from WHOOP Strain until a verified physiological model and device/workout validation exist.
