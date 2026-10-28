# WHOOP archive findings for PulseForge

This note is based on the private `Whoop.zip` archive in this repository. It records technical metadata and resource inventory only. It does not copy WHOOP source code, executable code, artwork, fonts or proprietary UI assets into PulseForge.

## App/container metadata found

- Bundle ID: `com.whoop.iphone`
- Display name: `WHOOP`
- Version/build: `5.75.0 (738478)`
- Minimum iOS: `18.0`
- Required capabilities: `bluetooth-le`, `arm64`
- Background modes: `bluetooth-central`, `external-accessory`, `fetch`, `location`, `remote-notification`
- External accessory protocol string: `com.whoop.wsbtp`
- Bluetooth and HealthKit usage descriptions are present in the archive.

## Bluetooth implementation clues

The compiled app contains CoreBluetooth API markers including:

- `CBPeripheral`, `CBCharacteristic`, `CBUUID`, `CBService`
- `scanForPeripherals`, `connectPeripheral`
- `didDiscoverServices`, `didDiscoverCharacteristicsFor`
- `didUpdateValueFor`, `setNotifyValue`, `writeValue`

The archive contains two 144-byte resources:

| Resource | Size | SHA-256 |
|---|---:|---|
| `HelloPacketRev3` | 144 bytes | `5d152eb178c554f0674c1d0fe279f15fb339d054f7bbbb5b8b14fd0ebb2d7105` |
| `HelloPacketRev4` | 144 bytes | `50d0c6c9c774ee4c91e6cba369eb70d10d061824305fc045283dcfdb6152e984` |

The binary scan found 88 UUID-shaped strings. Repeated candidate families include:

- `1150000x-6215-11ee-8c99-0242ac120002`
- `5983000x-5955-419b-bb8d-c8262926af23`
- `6108000x-8d6d-82b8-614a-1c8cb0f8dcc6`
- `8a58000x-2fe8-4796-9267-b87a2b0c8234`
- `8ec9000x-f315-4f60-9fb8-838830daea50`
- `fd4b000x-cce1-4033-93ce-002d5875f58a`

The binary's nearby printable strings provide additional clues:

- `8A580001-2FE8-4796-9267-B87A2B0C8234` and `59830001-5955-419B-BB8D-C8262926AF23` occur beside BLE scan-manager log strings.
- The `11500001-6215-11EE-8C99-0242AC120002` family occurs near pairing result strings and `WhoopBatteryPackCentralManagerQueue` / `WhoopStrapCentralManagerQueue`.
- The `FD4B0001-CCE1-4033-93CE-002D5875F58A` family also occurs beside those strap/battery manager names.
- The `61080001-8D6D-82B8-614A-1C8CB0F8DCC6` family occurs near `bleWriteValue` and an unknown-command parser error; `61080008/09` occur near strap Memfault/command strings.
- The `8EC90001-F315-4F60-9FB8-838830DAEA50` family is adjacent to `NordicDFU.DFUFirmware` strings and should be treated as firmware-update related, not assumed to be the live-data service.

These are string-neighborhood correlations only. They suggest candidate roles but do not prove which UUID is the primary service, which are characteristics, or which are used by WHOOP 5.0.

These are **unverified candidates**, not yet a confirmed GATT map. Some UUID strings may belong to third-party SDKs or unrelated components. Before implementing a connection profile, each candidate must be correlated with the CoreBluetooth discovery/write/notify call sites and then validated against the user's WHOOP 5.0 device.

## Data and feature inventory

The archive inventory found 86 JSON resources and 15 DTO/mock/schema resources relevant to areas including:

- Recovery, sleep need, HRV, resting heart rate, respiratory rate and blood oxygen
- Strain scale lookup and recovery-to-strain reference data
- Activity/workout and device connectivity resources
- Journal entries, behavior tracker summaries and histories
- Live heart-rate and sleep-performance widget localization resources

The JSON schema inventory records field names and value types only; sample payload values are not copied into PulseForge.

## PulseForge implementation policy

1. Keep the app independent from Goose and from WHOOP proprietary implementation/assets.
2. Use the archive to identify feature coverage, platform requirements, resource names and candidate device protocol metadata.
3. Treat every BLE UUID and packet interpretation as provisional until verified on-device.
4. Do not display fabricated recovery, sleep, strain or running scores. Unknown values remain blank until sourced.
5. Keep metric provenance visible: WHOOP sensor, Apple Health, or PulseForge calculation.


## Additional BLE and historical-sync diagnostics (inventory run 2026-10-27)

A second pass over executable strings found more useful diagnostic vocabulary:

- `Malformed HRM packet of length` and `Unknown packet type` indicate that the app has explicit HRM packet validation/parsing paths.
- Historical-transfer diagnostics include `Historical Pulls`, `HistoricalPullThroughputAnalyticsDataStore`, `HistoricalPullAnalyticsDataStore`, `History Start Packet`, packet append/processing queue messages, and parsed/failed packet counters.
- A string neighborhood around the `6108000x` family includes a log stating that characteristics with identifiers are being subscribed to, a `bleWriteValue(_:for:type:)` call-site marker, and an unknown-command parser error. This supports investigating this family for command/notification transport, but does not establish the exact characteristic mapping.
- The archive contains a dedicated `LiveHRView.strings` resource family, confirming a distinct live-HR feature surface; it does not expose a safe packet schema by itself.
- `8EC9000x` remains associated with Nordic DFU firmware resources and must not be treated as a live-HR candidate without further evidence.

### Implications for the reported WHOOP 5.0 symptoms

The user's earlier symptoms were live HR remaining at “Waiting” and historical transfer receiving metadata without packet bodies. The archive confirms that WHOOP has separate HRM parsing and historical-pull processing paths, so a generic BLE connection or successful GATT discovery is not sufficient to claim either feature works.

PulseForge should therefore implement and diagnose these as separate state machines:

1. Pairing/handshake and notification subscription.
2. Live-HR packet validation and timestamped sample delivery.
3. Historical range request, start/metadata handling, packet-body receipt, ordering, parsing and completion.

Do not send speculative commands or subscribe indiscriminately to every characteristic. The next protocol step is to map the exact characteristic roles and packet framing from call-site context, then validate the result on the WHOOP 5.0 hardware. These archive strings are diagnostic evidence, not a complete protocol specification.


## Protocol symbol inventory expansion (2026-10-27)

The expanded executable string inventory surfaced Swift symbol/type names that identify additional protocol layers. These names are useful architectural evidence, but they are not source implementations and do not reveal method bodies or wire formats.

### Pairing and handshake indicators

- `WhoopDeviceAPIs.HelloSending` and `WhoopAsyncDeviceAPIs.HelloSending`
- `WhoopAsyncDeviceAPIs.StrapHelloCompleteProviding`
- `WhoopStrapServices.HelloServicing` and `HelloRetryServicing`
- `WhoopStrapServices.UnlockTokenServicing`
- `WhoopStrapServices.ForgetBondServicing`
- `WhoopPacket.HelloResponse`, `HelloInfo`, and `HelloInfoProviding`

This establishes that WHOOP has a distinct hello/handshake and strap-unlock layer. It does not establish the required hello payload, sequence, key material, or pairing state transitions. PulseForge must not replay the bundled hello resources or invent an unlock exchange.

### GATT transport and characteristic roles

- `WhoopDeviceAPIs.SingleServiceCharacteristicMapping`
- `WhoopDeviceAPIs.PeripheralToCommandCharacteristicReducing`
- `WhoopCoreBluetoothAPIs.CharacteristicsSubscriberProtocol`
- `WhoopCoreBluetoothAPIs.PacketSendingProtocol`
- Lazy-storage symbols named `commandReadCharacteristic`, `commandWriteCharacteristic`, `dataReadCharacteristic`, and `eventReadCharacteristic`

These names strongly suggest separate command-read, command-write, data-read, and event-read characteristic roles. The executable string inventory does not prove their UUID assignments. The observed `6108000x` family remains a candidate transport family only; do not hard-code a mapping from string adjacency.

### Live-HR and historical-data layers

- `WhoopPacket.RealtimeHRPacket`
- `WhoopStrapServices.RealtimeHeartRateData`
- `WhoopStrapServices.RealtimeHrStreamingServicing`
- `WhoopStrapServices.HeartRateBroadcastServicing`
- `WhoopLiveHeartRate.HRStrapInteracting`
- `WhoopStrapServices.HistoricalPullServicing`
- `WhoopStrapServices.HistoricalDataStoring`
- `WhoopPacket.HistoryStartEvent` and `HistoricalSequenceable`

This supports keeping live-HR packet handling and historical-pull sequencing as separate implementations. It still does not provide a safe parser or command payload.

### Hello resource byte-layout observations (inventory run 2026-10-27)

The latest inventory now records the 144-byte Rev3 and Rev4 hello-resource bytes for offline structural comparison. A byte-level comparison shows:

- Both resources have the same total length (144 bytes) and share the same broad field layout.
- The revision marker at byte offset 0x0A changes from 0x03 (Rev3) to 0x04 (Rev4).
- A short ASCII identifier and a 64-character hexadecimal-looking field occur in the early payload; their meaning is not established. The latter is intentionally not reproduced in this document or used as an authentication value.
- The remaining tail contains repeated little-endian integer-like fields and a common four-byte trailer. Their semantics and checksum coverage are unknown.

These observations are **format fingerprints only**. They do not establish whether the resources are transmitted verbatim, how a revision is selected, whether any field is device-specific, or how hello response/unlock is authenticated. Do not replay either resource or synthesize a hello packet from these offsets.

The inventory's first Mach-O symbol-table pass found no matching protocol symbols in the extracted executable. The parser has now also been corrected to account for slice-relative symbol offsets in fat Mach-O files; the next run will show whether that correction changes the result. A zero result may still mean the executable is stripped or exports symbols through a different load-command mechanism.

The follow-up inventory also inspected the Mach-O export trie exposed through `LC_DYLD_EXPORTS_TRIE` / `LC_DYLD_INFO_ONLY`. It found no matching exported BLE/protocol names, while the corrected `LC_SYMTAB` parser also returned zero matching symbols. This means the current executable metadata does not provide a usable symbol-to-UUID map; nearby printable-string correlations remain unverified. PulseForge's passive GATT profile now records each characteristic together with its parent service UUID, so a real WHOOP 5.0 discovery session can provide the next grounded mapping evidence without sending commands or enabling notifications.

### PulseForge next-step constraints

1. Keep passive GATT discovery and property reporting; do not subscribe to every notify/indicate characteristic.
2. Correlate characteristic UUIDs with concrete type metadata and call-site evidence before assigning command/data/event roles.
3. Treat hello/unlock as a separate pairing state machine; do not send guessed handshake packets.
4. Implement live-HR and historical transfer only after packet framing, revision selection, validation and sequencing are independently understood.
5. Hardware validation on WHOOP 5.0 remains mandatory before marking either stream functional.


## Realtime IMU / raw-data parser evidence (2026-10-28)

A focused review of the supplied `whoop_stream_audit.txt` surfaced a substantially richer raw-data protocol vocabulary than the earlier inventory:

- `WhoopPacket.TurnOnRawDataCollectionCommand` and `TurnOnRawDataCollectionResponse`
- `WhoopStrapServices.RealtimeIMUData`, `IMUStreamServicing`, `RawDataStreamServicing`, `RealtimeStreamServicing`, and `RawDataCollectionServicing`
- `TurnOnRawDataCollectionCommandPacket`, `TurnOnRawDataCollectionCommandPacketRev2`, and a revision router
- `TurnOnRawDataCollectionResponsePacketRev1/Rev2` and a response revision router
- `RawDataPacketRev10`, `Rev11`, `Rev20`, and `Rev21`, each with separate parsing-error families
- `IMUPacketParsingError` cases for packet type, revision, timestamp epoch, metric-packet sequence, subsequence, accel/gyro reading counts, accel/gyro ranges, IMU sample rate, XYZ axes, reserved fields, and padding
- A demangled realtime/historical IMU data initializer signature that includes flags, timestamp epoch, metric sequence, subsequence, accel range, gyro range, IMU sample rate, and separate accel/gyro XYZ arrays
- `HarvardRawDataPart1/Part2`, `MaverickRawImuData`, and `ToggleHistoricalIMUData` identifiers

### Interpretation and implementation consequence

This evidence indicates that WHOOP raw IMU parsing is revision-aware and carries explicit metadata for timing, sequencing, ranges, sample counts and sample rate. It is not safe to infer a universal fixed 100 Hz layout or physical-unit scale from a single packet length/count pattern.

PulseForge's current experimental type-47 decoder (1244-byte frame, 100 accel + 100 gyro samples, fixed column offsets, accel /4096 g and gyro ×2000/32768 dps) must therefore remain **provisional and unverified**. Those offsets and scale constants have not been established by the symbol inventory. Do not use its output as calibrated activity classification or as proof of the official raw-data format.

### Next protocol work

1. Capture the complete raw type-47 frame metadata from a real WHOOP 5.0 session without changing command behavior.
2. Identify packet revision, timestamp epoch, sequence/subsequence, accel/gyro counts, ranges and sample rate before decoding axes.
3. Compare multiple consecutive frames for stable sequence/timestamp progression and count consistency.
4. Keep raw-data collection activation separate from IMU parsing and from realtime-HR activation.
5. Only promote axis scaling or stillness/activity thresholds after they are validated against a known controlled movement and the official parser's field vocabulary.

The audit provides protocol field names and parser architecture, not the missing byte offsets or a complete wire specification. No guessed command payloads or proprietary source code are copied into PulseForge.


## PulseForge safety correction: raw IMU activation and decoding (2026-10-28)

A code review found that the experimental implementation had promoted unverified assumptions into active behavior: it automatically sent START_RAW_DATA (opcode 0x51, payload [01]) and TOGGLE_IMU_MODE (opcode 0x6A, payload [01,01]) after the realtime-HR-on event, then treated every type-47 packet as a fixed 1244-byte, 100 Hz six-axis block with hard-coded offsets and scales.

The supplied archive audit does not establish those command payloads, activation ordering, type-47 revision, offsets, or physical-unit scales. The audit instead identifies revision-specific raw-data parsers (Rev10/11/20/21) and metadata fields for timestamp epoch, metric sequence, subsequence, sample counts, accel/gyro ranges and sample rate.

The implementation has therefore been made conservative:

- Realtime-HR activation no longer automatically triggers raw-IMU commands.
- A START_RAW_DATA response no longer automatically chains a TOGGLE_IMU_MODE write.
- Candidate type-47 frames are counted and timestamped only as packet observations; no synthetic axis samples, 100 Hz timing, or calibrated g/dps values are generated.
- The existing HR command path remains separate from raw-IMU activation.
- The code reports that raw-data activation and decoding are withheld pending verified wire-format evidence.

This intentionally reduces apparent IMU functionality but prevents fabricated sensor samples and speculative device commands. Restore raw-IMU streaming only after command bytes/revision routing and packet metadata offsets are established from a legitimate protocol trace or equivalent byte-level evidence, then validate on WHOOP 5.0 hardware.
