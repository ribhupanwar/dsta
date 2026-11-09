# DSTA release asset: direct WHOOP IPA inspection

Analysed 2026-11-09. Analysis migration required: no. No changes to lab physiological algorithms.

## Correction and verified input

The asset is named `pulseforge.ipa`, but its contents identify WHOOP, not the independent PulseForge
source application in DSTA. Earlier assumptions based on the filename/README were insufficient.
The file was actually downloaded; the release's published SHA-256 matches the local file.

- Source: https://github.com/ribhupanwar/dsta/releases/tag/whoop-5.75.0
- Asset ID: 684183934; bytes: 310125125.
- SHA-256: `8a5deedc59567612683feb77dd7348238de89437123946b3344bc6ff1e90af8a`.
- Top-level app: `Payload/Whoop.app`; executable `Whoop` (202700624 bytes).
- Bundle ID/display: `com.whoop.iphone` / WHOOP.
- Version/build: 5.75.0 / 738478; minimum OS 18.0.
- Main Mach-O `LC_ENCRYPTION_INFO_64`: cryptid 0, cryptoff 32768, cryptsize 173473792.
  The main executable does not declare an encrypted text region. No decryption was performed.
- Symbol table: 10437 entries. Queried feature names were mostly absent from that symbol table;
  feature strings/runtime metadata are present. Missing symbol names do not establish missing code.

Identity metadata and the repository asset digest do not independently validate Apple's signature or
prove the package is an unmodified official distribution. No signature/authenticity verification was run.

## Feature/protocol leads

The main executable has runtime/string references to Gen4/Gen5 characteristic mapping, live rep count,
set-detection streams, Strength Trainer and Healthspan models/UI. Examples observed include
`WhoopStrapGen5CharacteristicMapping`, `liveRepCount`, `dorsetDetectionStream` and
`HealthspanModelsProvider`. These are trace targets, not recovered implementations or validated BLE
packet layouts. The corpus can also contain localization, mock data, test strings and third-party SDKs.

The archive contains 86 JSON paths. No `.mlmodelc`, `.tflite`, `.onnx`, `.mlmodel` or `.jsbundle` path
was found in this initial filename inventory. That is not proof that no model/logic is embedded in some
other format, native binary, framework or remote service. No model weights or proprietary assets were
copied into the lab. The plain-text feature counts are retained in the machine-readable audit.

## Server dependence remains a separate question

URL host literals include `api.prod.whoop.com`, `coach.whoop.com` and app/CDN hosts, along with dev/QA
and mock references. This confirms reference strings exist, not that they are invoked, required for a
specific feature, or reachable without valid access. No request was sent to any WHOOP endpoint in
this audit. Downloads used GitHub release hosting only. Removing subscription UI does not reproduce
responses from a server or turn response models into an offline scoring algorithm.

## Reproduce without execution or asset extraction

```
python3 -m unittest discover -s Tools/lab -p 'test_*.py'
python3 Tools/inspect_ipa.py /path/to/pulseforge.ipa \
  --expected-sha256 8a5deedc59567612683feb77dd7348238de89437123946b3344bc6ff1e90af8a \
  --output audit.json
```

The stdlib-only tool reads plist/load commands and inventories literal counts. It executes nothing,
extracts no resource files, sends no network request and rejects unexpected executable layout/sizes.
Tests use synthetic archives, not the original executable. The original IPA remains outside this repo.

## Next verification boundary

Actual protocol integration needs field/call-site tracing, correlation with the owned WHOOP MG's
recorded events, independent implementation and tests against varying known inputs. UI/DTO/field-name
presence alone is insufficient. A complete original WHOOP clone and exact proprietary scoring have
not been delivered. The earlier WHOOP-Lab baseline was Woop-based. This fresh branch contains research tools and findings only; it does not import the Woop/NOOP application implementation.
