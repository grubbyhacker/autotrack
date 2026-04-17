# Agent Handoff

## Phase 4 lessons learned

### 1. Geometry and guidance must match

`Chicane` exposed a structural issue: mechanic geometry and verifier guidance cannot be treated as separate concerns.

If a sector's authored drive line differs materially from the flat straight centerline, `TrackGenerator.getLapPath(...)` or an equivalent path provider must supply intra-sector waypoints for that mechanic. Otherwise the verifier will "cheat" by driving the old straight path through new geometry.

This was fixed for `Chicane` by adding:

- `src/mechanics/ChicanePath.luau`
- mechanic-aware path generation in `src/track/TrackGenerator.luau`
- updated verifier path consumption in `src/verifier/VerifierController.luau`

### 2. Sector completeness is an invariant

We hit multiple bugs where a mechanic ended early and left empty space before the next corner.

This must be treated as a hard rule, not an aesthetic preference:

- any mechanic that consumes less than `Constants.STRAIGHT_LENGTH` must still provide continuous drivable surface to the sector boundary
- intentional gaps are allowed only if the mechanic explicitly defines a valid landing/rejoin path afterward

This rule is now also documented in:

- `AGENTS.md`
- `plans/phase4.md`

Tests should continue to assert this directly.

### 3. Fast inner-loop mode is essential

The fast test loop was necessary to make Phase 4 practical.

Use:

```lua
workspace:SetAttribute("AutoTrack_SkipBootBaseline", true)
```

before starting Play when iterating on a targeted mechanic slice.

Targeted Phase 4 commands supported in `TestRunner.server.luau`:

- `phase4`
- `phase4_pads`
- `phase4_rampjump`
- `phase4_crestdip`
- `phase4_chicane`

Workflow reminder:

1. edit local files in `/src`
2. stop Play
3. start Play again
4. trigger the desired test suite
5. stop Play again after validation

### 4. Runtime pass is not enough for shape-heavy mechanics

`CrestDip` originally passed runtime traversal, but the motion and shape were wrong because it was effectively a two-ramp sawtooth.

For future mechanics, visual/kinematic quality should be treated as a first-class acceptance criterion when curvature is the point of the obstacle.

`CrestDip` was improved by replacing the wedge with a sampled eased vertical curve in:

- `src/mechanics/CrestDipBuilder.luau`

### 5. Pads must affect runtime, not just rendering

Pads were initially only visual. The Phase 4 pad runtime test did not stabilize until pad speed effects were wired into the verifier loop.

Current runtime handling lives in:

- `src/verifier/VerifierController.luau`

Future pad-related changes should assume that rendering alone is insufficient; the runtime contract must be explicit.

### 6. TrackGenerator now has a mechanic dependency

`src/track/TrackGenerator.luau` now requires:

- `game.ServerScriptService.AutoTrackCore.Mechanics.ChicanePath`

That is acceptable for the current runtime, but a future refactor may want a cleaner dependency boundary between track generation and mechanic path providers.

### 7. Repo state at handoff

Phase 4 passed end to end at the conclusion of this work, but the repo is still mid-stream rather than cleaned up.

A follow-on agent should start with:

```bash
git status
```

and read the current diffs carefully rather than assuming only one narrow area changed.

## Recommendation before Phase 5

Address fixed-corner dynamics before starting Phase 5.

Reason:

- the current baseline track appears to allow unrealistic constant-speed cornering
- if corners behave like near-straight connectors, baseline lap time and slowdown measurements are distorted
- that would make Phase 5 mechanic integrity thresholds less trustworthy, especially for speed-management-heavy mechanics like `Chicane`

Recommended scope:

- treat this as a narrow "Phase 4.5" realism pass, not a full physics rewrite
- prioritize truthful corner pathing and speed behavior before visual polish

Suggested targets:

- fixed corners should expose a real constant-radius arc path for guidance
- verifier guidance should follow sampled arc waypoints through corners
- target speed should reduce through curvature rather than remaining globally constant
- speed recovery should happen after exit alignment, not immediately at corner entry
- add tests proving corners are traversed on a curved path and more slowly than flat straights

Visual improvement to corner surface/road presentation is useful, but secondary to making corner runtime behavior truthful.
