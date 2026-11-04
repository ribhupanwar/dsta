# PulseForge

A clean-room iOS wearable and training dashboard. The app uses independent SwiftUI, CoreBluetooth and HealthKit code; it does not reuse proprietary WHOOP app source or assets.

## Implemented foundation
- WHOOP-compatible BLE scan/connect, GATT diagnostics, standard heart-rate stream and vendor packet handling.
- WHOOP battery telemetry and Gen5 R21 IMU frame decoding with raw-frame diagnostics.
- Reconnect handling and local workout history persistence.
- Conservative automatic workout detection based on sustained elevated heart rate and a learned pre-session baseline. It is explicitly marked HR-only until motion-based detection is validated.
- Apple Health data access for HRV, resting heart rate, respiratory rate, blood oxygen, sleep stages and workouts.
- Running dashboard with HealthKit workout distance, pace, HR samples, zones and splits.

## Sleep, recovery and cardio-load calculations
- Sleep debt uses an eight-hour nightly target and the latest seven recorded sleep nights. Missing nights are not treated as zero sleep.
- Recovery is a PulseForge estimate using same-day HRV (60%) and resting HR (40%) against available prior-day baselines. It is not represented as a WHOOP score and remains blank until both current readings and baselines exist.
- Cardio-load points use workout heart-rate samples and the user's saved measured maximum heart rate. The app does not invent a max-HR value.
- A WHOOP-style 0–21 strain score is intentionally not shown until the underlying model has been validated.
- Unavailable or incomplete inputs remain blank rather than being replaced with fabricated metrics.

## Build
The `whoop-background-ble` branch includes a GitHub Actions build workflow. To build locally on macOS:

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project PulseForge.xcodeproj -scheme PulseForge -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO build
```

## Data and permissions
HealthKit readings require the user to grant access in Apple Health. A successful unsigned IPA build does not by itself guarantee that a sideloading signature preserves every entitlement; HealthKit permission behavior must be verified on the signed device build.


## Healthspan and VO2 estimate engine (feature branch)
- `PulseForge/HealthspanEngine.swift` adds a pure, local calculation layer for a transparent 0–100 Healthspan Index using up to nine WHOOP-inspired inputs across sleep, activity and fitness.
- Missing inputs are excluded and surfaced through coverage; they are never silently treated as zero.
- VO2 estimate fusion accepts separately sourced HealthKit, submaximal-run, race-performance and laboratory candidates, applies confidence/freshness weighting, and exposes disagreement.
- Effective-age math is provided only as a conversion for a caller-supplied, validated hazard ratio. PulseForge does not invent mortality coefficients or claim to reproduce WHOOP Age.
- The index is a wellness trend, not a biological-age test. A defensible age estimate needs validated, population-appropriate hazard ratios and overlap correction; a clinical biological-age clock generally needs laboratory biomarkers.
- Tests are in `PulseForgeTests/HealthspanEngineTests.swift`. Device data ingestion, HealthKit query wiring, UI, and an actual Xcode Actions build remain integration/verification steps.
