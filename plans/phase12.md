## Phase 12 — Visual Readability Pass

### Goal

Improve track readability and presentation without changing gameplay rules, schemas, repair logic, or verifier pathing unless a tiny structural change is required to support the visuals.

Primary goals:

- make the drivable road surface visually obvious on both straights and corners
- make straight sectors read as full sector "cells" instead of only narrow road slabs
- replace the verifier's red block look with a simple F1-style silhouette
- make `RampJump` read as a supported obstacle instead of a floating orange debug ramp
- make `Chicane` read as authored track geometry instead of blue/orange debug segments

### Constraints

- keep all code changes in `/src`
- preserve existing mechanics, schemas, lap path generation, and failure logic
- prefer visual overlays and styling over physics changes
- avoid new external asset/runtime dependencies when a procedural build is sufficient

### Final implementation

1. Added a shared sector-structure and rendering helper in `src/track/TrackVisuals.luau`.
   - every sector now owns fixed subfolders: `Anchor`, `Collision`, `Visual`, `Pads`
   - baseline shells and road visuals are rendered at sector level instead of being inferred from the collision root

2. Updated base track generation.
   - corners and straights now use the same structural composition model
   - ingress/egress transforms and lap path logic remain unchanged
   - flat road presentation is now a visual layer, not the collision root

3. Updated sector application and mechanic builders.
   - flat reapply/clear now preserve the new sector structure
   - mechanic collision pieces now live in `Collision`
   - pad parts now live in `Pads`
   - mechanic sector shells now live in `Visual`

4. Replaced verifier visuals.
   - retained a single physics root `BasePart` named `VerifierCar`
   - added welded non-colliding F1-style body panels/wheels

5. Added and updated automated coverage.
   - kept `phase1`, `phase2`, `phase4_chicane`, and `phase12` green under the maintained `make` workflow
   - updated tests away from the old flat folder-child-count assumptions where necessary
   - later follow-up cleanup kept the smooth-wave chicane centerline but changed the visible surface contract:
     - no chicane underlay ribbon
     - no segmented path edge lines
     - one visible path ribbon with explicit round join caps at turning vertices
     - stable manual review path via `phase4_chicane_capture`

### Test coverage

`TestPhase12` now validates:

- flat straight sectors expose sector shell + road + markings through the sector visual layer
- corner sectors expose sandstone shell + road arc + lane lines through the same sector visual layer model
- `RampJump` creates support visuals
- `Chicane` keeps a sector shell and uses side-band stripes instead of full-width road paint
- `Chicane` visual follow-up coverage verifies the smooth-wave overlay remains denser than collision, omits underlay/edge lines, and includes join-cap coverage
- `VerifierCar` root remains present while carrying child visual parts

### Non-goals

- marketplace asset ingestion as a runtime dependency
- new mechanics
- UI redesign
- physics retuning for aesthetics alone
