# WHOOP 5.0 Gen5 metric cross-check: original WHOOP IPA vs NOOP vs OpenStrap

Date: 2026-11-01
PulseForge base commit reviewed: f310e874360be9c8e03c03899ed2f15cc85f62b4
Original app reference: WHOOP iOS 5.75.0 (build 738478), archive `com.whoop.iphone_5.75.0_und3fined.zip`
NOOP reference: `woop-apk-decompiled-analysis` GitHub Actions artifact (run 41275434886, artifact 13070907185)
OpenStrap reference: `OpenStrap/protocol` commit `89080bcfac7767b3a871fd3a7d9307f5f30dad26`; `OpenStrap/edge` current main tree reviewed.

## Executive result

The three references are useful for different things and must not be treated as equally authoritative:

1. **Original WHOOP IPA is the primary reference for the official app's feature surface and its own protocol architecture.** Its extracted inventory confirms WHOOP's app has health-monitor concepts for respiratory rate, blood oxygen, RHR, HRV and skin temperature, and contains a `/coaching-service/v2/sleepneed` route. It also contains BLE abstractions for historical pulls, realtime HR, raw-data collection and IMU. The available static inventory does **not** establish Gen5 BLE byte offsets or prove that WHOOP calculates Sleep Need locally.
2. **OpenStrap protocol provides the clearest current byte-level Gen5 v18 field map**, with real CRC-verified captures and explicit uncertainty annotations. It is a third-party implementation, not WHOOP's source.
3. **NOOP provides useful independent implementation cross-checks and candidate analytics**, but its labels and heuristics are not official WHOOP semantics. In particular, it calls the Gen5 SpO2 byte a candidate rather than a validated percentage.

No metric below should be labelled an official WHOOP score unless confirmed against original WHOOP behaviour and real band captures.

## Gen5 v18 field cross-check

Offsets below are relative to the v18 inner payload. OpenStrap documents that the Gen5 outer frame has an 8-byte header, so the corresponding frame-absolute offset is inner offset + 8.

| Signal | OpenStrap protocol finding | NOOP cross-check | PulseForge status at reviewed commit |
|---|---|---|---|
| HR | `inner[14]`, u8, plausible 25–230 bpm | Consumes Gen5 historical HR | Decoder already reads frame[22] |
| RR count / intervals | Count at `inner[15]`; accepted intervals follow in the v18 record; values are signed little-endian 16-bit milliseconds after validation | NOOP HRV engine applies RR cleaning and coverage gates | Existing decoder is candidate/fixture-derived; needs continued parity tests against OpenStrap real fixtures |
| Sleep envelope | `inner[73]`, sleep state in bits 4–5: 0 wake, 1 still, 2 sleep, 3 up | NOOP SleepStager has `bandStateAsleep = 2` | PulseForge stores the raw frame[81] byte only; correct conservative choice |
| SpO2 candidate/status | `inner[74]` / frame[82]. Field family is established, encoding is **not**; not every nonzero byte is a percentage | NOOP stores the same auxiliary byte as `auxByte82`; its `nightlySpo2CandidateMean` only admits candidate values 70–100 and names the result a candidate | Not decoded/displayed yet; do not convert to SpO2 % |
| Step motion counter | `inner[49:51]`, u16 LE cumulative on-chip counter. OpenStrap says it is near-monotonic, but explicitly says the semantic name is still inferred pending producer proof | NOOP has a further motion/cadence/sleep-aware step estimation pipeline | Not implemented in PulseForge; promising lead, not a cracked step algorithm |
| Step cadence | `inner[51]`, u8. OpenStrap says the smooth 51–254 behaviour is pinned, but the “cadence” label remains inferred | NOOP uses cadence and gait bouts as corroboration | Not implemented in PulseForge |
| Activity class | `inner[55]`; 0/1/2 are known-valid codes, with 0 meaning unknown/unclassified | NOOP uses activity-class context in step validation | Not implemented in PulseForge |
| Skin temperature | `inner[65:67]`, signed i16 LE, °C = raw / 100. Exact -5000 (= -50.00 °C) is unavailable/error sentinel | NOOP's Gen5 path stores and trends skin temperature, separately from a clinical body-temperature reading | Not implemented in PulseForge |
| Auxiliary temperature 1/2 | `inner[61:63]` and `inner[63:65]`, signed i16 LE, °C = raw / 10; OpenStrap identifies these as fuel-cell and ambient channels | NOOP archives v18 auxiliary bytes/diagnostics | Not implemented in PulseForge |

### SpO2: critical caveat

The byte at inner[74] is a real SpO2-related candidate/status field, but OpenStrap explicitly declines to publish it as a percentage because its encoding is not pinned. NOOP independently reads the corresponding frame byte as `auxByte82`, filters 70–100 and computes a nightly candidate mean. This is useful evidence to capture and correlate, **not proof that the raw byte equals a measured saturation percentage**.

Next validation needed: capture many WHOOP 5.0 Type-47 v18 records across sleep and wake; correlate inner[74] with inner[73] sleep state, v20 optical records, v26 PIP records, and any original-WHOOP raw-data/SpO2 pipeline evidence. Keep the byte raw until a deterministic encoding is demonstrated.

### Skin temperature vs body temperature

The Gen5 v18 map gives a calibrated **skin** temperature. It is not core body temperature. The two auxiliary temperature channels have different scales and are labelled by OpenStrap as cell and ambient temperatures; they must not be relabelled as body temperature. Preserve all three separately, along with sentinels and source timestamps.

### Sleep stages

The v18 sleep state is only a coarse envelope. All sleep stages (Deep, Light/Core and REM) share the same “sleep” state. It can help identify the broad sleep interval but cannot directly produce a hypnogram. Stage estimation requires a separately validated algorithm using HR/RR, motion and other features, and must be labelled as an estimate unless confirmed by original WHOOP data.

## NOOP algorithm references (not WHOOP official formulas)

- **HRV:** `HrvAnalyzer` uses RR range 300–2000 ms, local ectopic rejection threshold 20%, 2-beat neighbour radius, minimum 20 beats, and 5-minute rolling windows. It includes over-count and coverage checks. These are NOOP's implementation choices.
- **RHR:** `PrimarySessionRestingHR` derives an average from a selected primary session with valid-BPM and sample-coverage gates. This is not proof of WHOOP's proprietary RHR algorithm.
- **Sleep debt:** `SleepDebt` defaults to 8 hours' need and a 14-night window. Its recurrence is `max(need + previousDebt - slept, 0) * 0.55`, with debt reset below 10 minutes. This is a useful transparent local estimate, not the official WHOOP Sleep Need/debt implementation.
- **Recovery:** `RecoveryScorer` is a NOOP composite using HRV/RHR/sleep/respiratory/skin-temp/activity drivers and a logistic transform. Its weights and constants are NOOP-specific and must not be copied or labelled as WHOOP Recovery.
- **SpO2:** NOOP's v18 byte path is explicitly a candidate mean. It is not enough to justify a percentage display.

## What the original WHOOP IPA confirms

The 5.75.0/build 738478 inventory includes:
- Health Monitor keys: `RESPIRATORY_RATE`, `BLOOD_OXYGEN`, `RHR`, `HRV`, `SKIN_TEMPERATURE_CELSIUS`, `SKIN_TEMPERATURE_FAHRENHEIT`.
- Sleep Need resources and the `/coaching-service/v2/sleepneed` endpoint.
- BLE architecture symbols including `HistoricalPullServicing`, `RealtimeStreamServices`, `RealtimeHeartRateData`, `RawDataStreamServicing`, `IMUStreamService`, `WhoopPacketRevisionRouter`, and packet/CRC types.

This confirms the official app's metric and service surface, but the inventory is not a source-level decoder. It does not validate the Gen5 offsets above, nor does it show that Sleep Need is computed on-device. The presence of the Sleep Need service endpoint strongly suggests that the official Sleep Need path includes a service response.

## PulseForge implementation plan

1. Extend the Type-47 v18 decoder to preserve raw SpO2 candidate byte, calibrated skin temperature, both auxiliary temperature channels, step counter/cadence and activity class. Add field-level tests using the OpenStrap CRC-verified fixture and synthetic boundary/sentinel fixtures.
2. Keep raw SpO2 candidate and quality metadata visible only in diagnostics; no percentage until encoding and optical correlation are validated.
3. Show skin temperature as WHOOP-band skin temperature, not body/core temperature. Do not mix auxiliary cell/ambient channels into it.
4. Derive coarse sleep windows from the validated sleep envelope plus timestamp continuity; do not claim Deep/REM/Core from that byte.
5. Implement a clearly labelled local sleep-debt ledger using actual band-derived sleep duration. Keep NOOP's 8h/14-night/55%-carry model as a candidate to test, not as WHOOP's official formula. Personal sleep need needs its own calibration and evidence.
6. Revisit official WHOOP Recovery only after overnight RR/RHR, sleep and temperature signals have verified coverage. Do not reuse NOOP's RecoveryScorer weights as if official.
7. Validate every new field against live WHOOP 5.0 captures and the original app's displayed values where available.

## License / provenance

OpenStrap protocol is AGPL-3.0. Its findings can guide independent implementation and tests, but copying implementation code into PulseForge requires a separate license review. This note records field facts and provenance, not a code transplant.
