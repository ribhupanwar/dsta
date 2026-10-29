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
