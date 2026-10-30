# WHOOP UI parity implementation map

Reference: decoded WHOOP iOS UI archive from workflow run 4 (artifact `whoop-ui-reference-decoded`).
Target: PulseForge on iPhone 18 Pro Max / iOS 27.0.
Acceptance: match the reference hierarchy, geometry, spacing, typography, colors, rings, charts, cards, navigation, and interaction states as closely as SwiftUI permits. Never fabricate physiological values to fill a visual slot.

## Verified reference inventory

The decoded archive contains:
- `ActivityStrainView.nib` (313 objects / 1,950 values)
- `ActivityListView.nib`, `ActivityListTableHeaderView.nib`, `ActivityListTableViewCell.nib`
- `StrainCoachView.nib` and `StrainCoachViewNew.nib` (large recovery/strain graph surfaces)
- `Home.storyboardc/HOME_ID.nib`
- `Main.storyboardc/COACH_ID.nib`
- Sleep Coach storyboard, Sleep Need receipt views, recommended-time and menu components
- `ActivitySettingsViewController.nib`, activity selector and settings cells
- WHOOPDesign and Sleep Coach asset catalogs
- extraction error files are empty.

## Current PulseForge baseline (branch feature/export-whoop-rr-raw-archive)

- Main navigation currently exposes Today, Sleep, Strain, Run, WHOOP.
- Today has a recovery ring, compact metric rows, live HR card/chart, historical RR evidence card.
- Sleep has a performance placeholder ring, sleep duration, Sleep Need/Debt placeholders, stage breakdown and source disclosure.
- Strain shows a PulseForge workout cardio-load estimate and recent run details. It explicitly disclaims equivalence to WHOOP's proprietary 0–21 score.
- Recovery is currently a detail sheet reachable from Today, not a first-class destination.
- Activity history and Coach are not first-class destinations yet.
- UI currently uses a custom lime-accented dashboard style; reference assets and nib structures must guide the visual system replacement.

## Implementation order

1. **Design system and navigation shell** — extract exact color, type, spacing, card/radius, icon and tab conventions from decoded reference; establish reusable SwiftUI tokens; map primary destinations.
2. **Home / Today** — reproduce WHOOP dashboard hierarchy, summary cards and ring geometry while binding only validated PulseForge values.
3. **Recovery** — promote to a full screen; preserve the validated-input gate. Show unavailable states in the same visual language rather than synthetic percentages.
4. **Sleep** — reproduce performance, stages, sleep graph and Sleep Need receipt hierarchy. Keep Apple Health fallback visibly distinct from WHOOP-native data.
5. **Strain and Activity** — build the activity list/detail and day-load surfaces. Label PulseForge cardio load distinctly until all-day HR and motion inputs validate WHOOP-equivalent scoring.
6. **Coach** — add coaching cards and trend surfaces backed by real run/workout history; no unsupported readiness advice.
7. **Pixel and interaction QA** — compare reference and PulseForge screenshots at the same iPhone 18 Pro Max logical size; check scroll, selected tabs, empty/loading states, expanded cards and dynamic type.

## Data integrity constraints

- Phone packet receipt time is not a physiological timestamp.
- Type-47 RR archive counts are evidence of stored frames, not proof of an overnight sleep window.
- Overnight HRV requires verified physiological timestamps and a validated sleep interval.
- Recovery requires validated overnight HRV and resting-HR inputs/baseline.
- Sleep Need/Debt require verified night grouping and a learned personal baseline; heuristics must be labelled PulseForge estimates.
- Workout cardio load is not WHOOP's proprietary 0–21 Strain.
- Apple Health sleep/workout data may be shown only with explicit source labels; it must not silently populate WHOOP-native metrics.

## Current first-pass gaps confirmed from source

- Tab shell is five destinations and does not yet expose Recovery, Activity or Coach as first-class screens.
- Sleep dashboard's main score is intentionally empty; sleep duration/stages are Apple Health fallback.
- Recovery detail remains a sheet and has no verified score yet.
- Strain ring progress is currently a placeholder (zero trim); the screen is a workout cardio-load summary, not a WHOOP Strain replica.
- No screenshot-diff/visual regression target is configured in the inspected workflow.

This document is a parity implementation map, not a claim that the UI is already matched.
