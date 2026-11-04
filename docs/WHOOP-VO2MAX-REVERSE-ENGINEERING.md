# WHOOP 5.75.0 VO2 Max reverse-engineering findings

Audit date: 2026-11-04  
Pinned IPA: WHOOP 5.75.0, build 738478  
Bundle identifier: `com.whoop.iphone`  
IPA SHA-256: `8a5deedc59567612683feb77dd7348238de89437123946b3344bc6ff1e90af8a`

## What was verified

The original IPA was downloaded from the repository's pinned release, its SHA-256 matched the expected digest, and `unzip -t` passed. The ARM64 executable was extracted and inspected with `strings`, `nm`, Swift demangling, and `otool -tvV`. The GitHub Actions audit completed successfully and uploaded the evidence artifact.

The executable contains a WHOOP historical-trends module with these route strings:

- `/progression-service/v3/trends/`
- `/manual/readings`
- `/manual/readings/paginated?next_token=`
- `/readings/paginated?next_token=`

It contains VO2-related data keys and model fields, including:

- `vo2max_score`
- `vo2MaxMeasurement`
- `vo2MaxValue`, `vo2MaxUnit`
- `cardioFitnessLevel`
- `score_timestamp`

The app defines VO2 measurement source types:

- `INTERNAL_ESTIMATE`
- `MANUAL_LAB_TEST`
- `MANUAL_OTHER`
- `MANUAL_WEARABLE`

The binary also references HealthKit's `HKQuantityTypeIdentifierVO2Max`, and the app metadata includes HealthKit read/write usage descriptions. This establishes that HealthKit VO2 Max integration exists in the WHOOP app.

## What this does not establish

No self-contained VO2 Max estimation formula, coefficient set, or on-device model was identified in this static audit. The presence of `INTERNAL_ESTIMATE` is a source/type label, not proof that the estimator runs locally. The trend routes and `vo2max_score` key indicate that VO2 trend data is handled by the progression/trends service; further request/response and runtime analysis is needed to establish where the internal estimate is computed.

The strings `CardioFitnessLevelModel` and `VO2MaxManualMeasurementModel` are UI/data model evidence only. They do not reveal the underlying physiological algorithm.

## PulseForge implementation guidance

1. Preserve the existing HealthKit entitlement and integration. Do not remove HealthKit.
2. Treat a valid HealthKit VO2 Max sample as an externally measured/source-labelled value, not as a PulseForge estimate.
3. Keep WHOOP-derived values separate from PulseForge-derived estimates and retain source, timestamp, confidence, and provenance.
4. Do not label a GPS/heart-rate heuristic as WHOOP-equivalent.
5. For an independent estimator, require sufficiently long, steady, quality-controlled running data and explicit eligibility checks; prefer a validated published method or laboratory/HealthKit measurement when available.
6. Add tests for units, outlier rejection, sample freshness, and source precedence before surfacing an estimate.

## Audit artifact

GitHub Actions run: https://github.com/ribhupanwar/dsta/actions/runs/41804651721  
Artifact: `whoop-original-ipa-vo2max-evidence` (retention expires 2026-11-18 unless downloaded/preserved).

