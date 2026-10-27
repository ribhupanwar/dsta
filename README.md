# PulseForge

A clean-room iOS wearable and training dashboard project. This project does not reuse Goose source code or WHOOP proprietary implementation/assets.

## Current foundation
- Native SwiftUI dark dashboard with Today, Sleep, Strain and Device areas.
- Apple Health authorization scaffold for heart rate, HRV, resting heart rate, sleep and workouts.
- No fabricated metrics: unavailable readings display as dashes until a real source is connected.
- WHOOP archive is a technical reference for app metadata and resource inventory only. BLE identifiers and packet semantics must be verified before implementing pairing or historical sync.

## Build
Install XcodeGen, then run:
```sh
xcodegen generate
xcodebuild -project PulseForge.xcodeproj -scheme PulseForge -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO build
```

## Planned implementation order
1. Inventory archive metadata and device resource identifiers.
2. Verify WHOOP 5.0 BLE handshake and notifications with the physical device.
3. Implement live heart rate and stable reconnect.
4. Implement historical transfer with packet-level diagnostics.
5. Add sleep, recovery and strain calculations with transparent data provenance.
6. Add workout export and running analytics.

## Important
The original WHOOP archive is a compiled app bundle, not an editable source project. It cannot simply be converted into a new app source tree. This project uses independent code and UI.
