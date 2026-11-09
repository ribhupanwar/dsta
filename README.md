# WHOOP original-IPA rebuild research

Fresh work based on the owner-provided DSTA release `whoop-5.75.0/pulseforge.ipa`.
This branch does not use Woop/NOOP application source as a baseline. The original IPA is kept
outside this source tree; no original executable, icons, fonts or app assets are redistributed here.

## What exists now

- Direct archive identity and Mach-O inventory: WHOOP 5.75.0 (738478), `com.whoop.iphone`.
- Published asset SHA-256 verified; main executable declares `cryptid=0`.
- Read-only audit tooling and initial feature/server-host evidence.
- 38 candidate UUID string locations and 314 candidate AArch64 ADRP/ADD references, needing
  disassembly/register-flow and actual-device validation. This is not yet a verified GATT role map.

## Current boundary

This is active reverse-engineering research, **not a completed app, recovered source or installable
clone**. No original algorithm, server response, paid access, automatic reps or Healthspan equivalence
is claimed. Future implementation must be independent, source-labelled and verified on the owned band.
Main DSTA and the stable Woop app are not modified by this isolated research branch.

See [identity report](research/ipa-identity.json), [analysis notes](research/ipa-analysis.md) and
[UUID reference candidates](research/gatt-reference-candidates.json).

## Tools

`Tools/inspect_ipa.py` uses the Python standard library. `Tools/trace_uuid_references.py` additionally
uses NumPy to identify possible code references without executing the app. Reference candidates do
not prove which characteristic is command/data/event or that a feature will work offline.

Analysis migration required: no. No production scoring or device state is changed by this branch.
