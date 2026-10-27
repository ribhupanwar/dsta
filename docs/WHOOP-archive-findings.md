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
