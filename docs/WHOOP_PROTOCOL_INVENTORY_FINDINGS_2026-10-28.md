# WHOOP 5.0 protocol analysis — inventory findings (2026-10-28)

## Evidence source
WHOOP iOS app archive supplied by the repository owner, identified by the generated technical inventory as app version 5.75.0 (build 738478), minimum iOS 18.0. The inventory workflow completed successfully on 2026-10-28 (GitHub Actions run 40615753753). This document records static metadata and symbol/resource names only; it does not claim to have decoded proprietary packet contents.

## Confirmed from the archive inventory
- The app declares Bluetooth-central background mode and the external accessory protocol `com.whoop.wsbtp`.
- CoreBluetooth markers include peripheral/service/characteristic discovery, notification subscription, writes, scanning, and connection.
- WHOOP vendor UUID family observed: `FD4B0001`, `0002`, `0003`, `0004`, `0005`, `0007`, `0008`, `0009`, all with base `-CCE1-4033-93CE-002D5875F58A`.
- The UUID strings are candidate strings from the executable inventory. Their role and properties must be established from a live GATT snapshot; do not hard-code semantic labels based on UUID number alone.
- Two embedded pairing resources exist: `HelloPacketRev3` and `HelloPacketRev4`, each 144 bytes. Their SHA-256 fingerprints are:
  - Rev3: `5d152eb178c554f0674c1d0fe279f15fb339d054f7bbbb5b8b14fd0ebb2d7105`
  - Rev4: `50d0c6c9c774ee4c91e6cba369eb70d10d061824305fc045283dcfdb6152e984`
  The inventory did not export the packet bytes, so these hashes cannot be used to reconstruct the packets.
- Protocol symbols/names indicate distinct services for hello exchange/retry, strap unlock token, real-time HR, real-time IMU, real-time stream, raw data stream, historical pull, and HR broadcast.
- Relevant names include `HelloPacketRev3/Rev4`, `HelloResponsePacketRev3/Rev4`, `HelloResponsePacketRevRouter`, `AsyncHelloSender`, `AsyncHelloRetryService`, `StrapUnlockTokenService`, `RealtimeHeartRateData`, `RealtimeIMUData`, `IMUStreamServicing`, `RealtimeHrStreamingServicing`, and `HistoricalPullService`.

## What this means for our current BLE issue
A successful GATT connection and CCCD subscription are not proof that the WHOOP session is initialized. The archive's symbol inventory strongly suggests a hello/response and unlock/session stage before dependable real-time streams. This is a hypothesis supported by symbol names, not a decoded protocol specification.

Our previous captures showed notifications on FD4B0004 (including 36-byte and 44-byte payloads), and occasional HR samples. Those observations are consistent with receiving data before or during an incomplete session, but they do not establish that FD4B0004 is always an HR channel.

## Next implementation/debug sequence
1. Preserve the existing raw notification logger. For each event record timestamp, peripheral identifier, service UUID, characteristic UUID, byte count, hex bytes, RSSI, connection generation, notify-state, and whether a hello response has been observed.
2. Add a connection-generation state machine: disconnected → connected → services discovered → characteristics discovered → notifications enabled → hello sent → hello response parsed → unlock/session complete → stream active. Reset all session flags on disconnect and service invalidation.
3. Capture the exact 144-byte Rev3/Rev4 hello resource bytes from the archive in a local, owner-controlled analysis environment. Compare them byte-for-byte and determine which revision the strap expects. Do not guess or synthesize a hello packet.
4. Record write-with-response vs write-without-response, write completion/error, notification ordering, and the first 10 seconds after hello. Do not repeatedly subscribe to the same characteristic or start duplicate hello tasks.
5. Only label a characteristic as HR/IMU after correlating payloads against controlled tests and/or a known-good official-app capture. Keep unknown payloads raw.
6. Once session establishment is stable, decode HR and IMU independently; then implement recovery/sleep/strain calculations from validated data sources.

## Acceptance criteria
- 10 consecutive connect/disconnect cycles complete without manual retry loops.
- Each connection produces exactly one hello/session attempt at a time.
- A parsed/validated session-complete event precedes stream-active state.
- HR samples arrive repeatedly with monotonic timestamps and plausible values; stale samples are marked stale rather than displayed as live.
- IMU samples are timestamped and validated for units, axes, sample rate, and packet loss before exposing them to workout features.
- No recovery, sleep, or strain score is presented as measured WHOOP data unless it is sourced from a validated WHOOP record; derived estimates must be explicitly labeled.

## Safety and scope
This work is limited to analysis of the owner's lawfully obtained app archive and communication with the owner's paired device. Do not bypass account controls, subscription checks, or device security; do not copy signing credentials or proprietary app assets into this repository.
