# Phase 11 — Challenge Rewards: Incentivising Exciting Obstacles

**Status:** 11a–11c implemented on the current branch; 11d partially implemented.
Automated validation currently green for:

- `make phase6_unit`
- `make phase10_unit`
- `make phase11_unit`
- `make phase11_integration`

Implementation remains split into four sub-phases (11a–11d), but the repo state
has advanced beyond the original prototype notes below.

**Author:** Session of 2026-04-17 (overnight design pass).

---

## 1. Problem statement

Through Phase 10 the CI loop reliably produces **minimum-valid** obstacles and nothing
more. Two observations motivate Phase 11:

1. `LevelMappings.DEFAULTS` and the qualifier bias tables are tuned to just clear
   the integrity threshold. The repair loop actively walks extreme proposals *back*
   toward the minimum (e.g. CrestDip airtime-too-long → height −2). As a result,
   a committed crest after 3 attempts looks basically like a committed crest with
   zero qualifiers: small, pass-the-gate, unexciting.
2. Integrity evaluators are boolean gates (`ok, hints`). There is no signal in the
   system that says "this ramp is *better* than that ramp." Both commit identically.

The user asked this out loud: *"Right now I don't feel like the agents have any
reason to create a larger jump, crest or deeper chicane."* That is correct, and it
is a reward-function problem, not a repair-loop problem.

## 2. Goal

Introduce a **fitness signal** (the *ChallengeScore*) and a **track-wide budget
constraint** (*slowdown budget*). Together they turn the existing
satisfice-the-gate agent into a **maximise-under-budget** agent without breaking
any existing integrity rules or the visible lap contract.

Success criteria:
- A `/demo maximize` session builds a track that is visibly harder than a default
  track of the same mechanics, end-to-end, in one continuous watchable run.
- The HUD shows a per-sector score and a track-wide total.
- No regressions in phases 4–10; all existing suites still pass.
- Total lap time stays within `baseline × (1 + CHALLENGE_BUDGET_RATIO)`.
- Player-facing score wording remains minimal; see `plans/adr-phase11-scoring-reporting.md`.

## 3. Design

### 3.1 ChallengeScore — a scalar per committed sector

After a *successful* run, LapEvaluator computes a `ChallengeScore` from the
existing `RunMetrics` plus a small number of new telemetry fields. It is a sum of
weighted components, each normalised to roughly `[0, 10]`:

| Component      | Intuition                                     | Source                                     |
|----------------|-----------------------------------------------|--------------------------------------------|
| `air`          | hang time + peak height during liftoff        | `hang_time`, `target_air_distance`         |
| `lateral`      | how hard the car is cornering                 | `target_left_offset`, `target_right_offset`, estimated peak lateral g |
| `near_miss`    | how close the car came to failing integrity   | margins to `CRESTDIP_MAX_AIRTIME_DISTANCE`, `RAMPJUMP_REACQUIRE_MAX`, chicane corridor edge |
| `time_cost`    | *negative*; how much slower this sector is vs the clean-track same-sector time | `sector_exit_speed - sector_entry_speed`, `lap_time` delta |

Prototype formula (see `src/integrity/ChallengeScore.luau` on this branch):

```
total = W_AIR * air
      + W_LATERAL * lateral
      + W_NEAR_MISS * near_miss
      - W_TIME * time_cost
```

All weights are exposed on `Constants` as `SCORE_W_*` so they can be retuned
without source edits in tests.

**Why `near_miss`?** The user explicitly called it out: a crest that almost flies
the car off the end of the sector should score higher than a crest that the
verifier handles with comfortable margin. Near-miss turns margin *to* integrity
thresholds into a reward signal, which is exactly the gradient the agent needs.

### 3.2 Slowdown budget — a hard constraint

`baseline_lap_time` already exists. Add `CHALLENGE_BUDGET_RATIO = 0.5` (v1). A
committed track must satisfy:

```
current_lap_time ≤ baseline_lap_time × (1 + CHALLENGE_BUDGET_RATIO)
```

The constraint is checked at two levels:
- **per-job:** after a would-be commit, if the projected lap time crosses the
  budget, the commit is rejected and the job reverts. This is *in addition to*
  the integrity gate, not a replacement for it.
- **campaign-level:** the maximiser evicts the lowest-scoring sectors until
  within budget. (See §3.5.)

### 3.3 Two-stage acceptance: Integrity → Challenge-up

Single-sector jobs gain an optional second stage:

1. **Stage A — Integrity (existing):** propose → verify → repair until pass or
   exhaust.
2. **Stage B — Challenge-up (new, opt-in):** once a sector commits, apply a
   *score-increasing* mutation (e.g. `ramp_angle += 2`) and re-verify. If it
   still passes integrity *and* stays within budget *and* scores strictly
   higher, replace the commit. Repeat up to `CHALLENGE_UP_ROUNDS = 3` times or
   until a mutation regresses. If any mutation fails, the previous best commit
   is preserved (rollback to snapshot, not to baseline).

Stage B is gated by a qualifier keyword (`extreme`) or by `/demo extreme`. It is
off by default so existing suites do not get slower.

### 3.4 Score-aware proposer

`MinimalProposer` gets a new entry point `escalate(state, score) -> AgentAction?`
used only during Stage B. It consults a per-mechanic **EscalationLadder** that
ranks levers by expected score delta:

```lua
ESCALATION_LADDER = {
  RampJump = { "ramp_angle", "gap_length", "ramp_length" },
  Chicane  = { "amplitude", "transition_length" },  -- tighter is harder
  CrestDip = { "height_or_depth", "sector_length" }, -- shorter is harder
}
```

The repair ladder is unchanged. Escalation is a *separate* path.

### 3.5 The maximiser — `/demo maximize`

A single-agent campaign that writes a full challenging track in one visible run.
Loops:

1. Publish baseline. Verify `AutoTrack_BaselineLapDone`.
2. For each editable straight (in randomised order):
   - Pick a mechanic from a weighted distribution (`RampJump:0.4`, `Chicane:0.3`,
     `CrestDip:0.3`).
   - Submit `"add a <mechanic> in sector N"` with `extreme` qualifier.
   - Log committed score and running total.
3. After the final sector, run one full-lap budget check. If over budget, evict
   the lowest-score sector (revert to baseline flat) and retry. Repeat until
   under budget or all non-zero-score sectors are gone.
4. Publish `track_score`, `budget_used`, `budget_headroom` to UIState.
5. Stop.

This is **the watch-mode**. It is the first thing in the project that looks like
a multi-decision agent rather than a one-shot repairer. Budget-eviction is the
part that will read most clearly on camera (the "sacrificing a sector to fit the
budget" moment).

## 4. Schema additions (additive, backward-compatible)

### 4.1 `RunMetrics` new fields
- `hang_time: number` — longest continuous airborne duration in seconds (target
  sector preferred; lap-global if target sector not airborne).
- `peak_lateral_g: number` — peak frame-to-frame lateral acceleration estimate
  (studs/s²).
- `target_min_speed: number?` — minimum speed observed while inside the target
  sector. Useful for chicane near-stall scoring.

All default to `0` so pre-existing evaluators are unaffected.

### 4.2 `RunResult` new field
- `score: ChallengeScore?` — populated only on `success`. Nil otherwise.

### 4.3 New type `ChallengeScore`
```lua
type ChallengeScore = {
  total: number,
  air: number,
  lateral: number,
  near_miss: number,
  time_cost: number,
  budget_used: number,   -- fraction of the session slowdown budget
  over_budget: boolean,
}
```

### 4.4 `Constants` additions
```lua
Constants.CHALLENGE_BUDGET_RATIO      = 0.50
Constants.CHALLENGE_UP_ROUNDS         = 3
Constants.SCORE_W_AIR                 = 1.0
Constants.SCORE_W_LATERAL             = 1.0
Constants.SCORE_W_NEAR_MISS           = 1.5
Constants.SCORE_W_TIME                = 0.25
Constants.NEAR_MISS_ZERO_AT_MARGIN    = 0.75  -- fraction of threshold where score ramps to 0
Constants.LATERAL_G_FULL_SCORE        = 60    -- studs/s² -> 10 points
Constants.HANG_TIME_FULL_SCORE        = 0.75  -- seconds  -> 10 points
```

## 5. Rollout: 11a → 11d

Each sub-phase is independently shippable. Order matters because later phases
depend on the telemetry and hooks from earlier ones.

### 11a — Scoring infrastructure (prototyped on this branch)
- Add `src/integrity/ChallengeScore.luau` (pure function, no side effects).
- Extend `RunMetrics` with `hang_time`, `peak_lateral_g`, `target_min_speed`.
- Extend `RunResult` with optional `score`.
- Wire `ChallengeScore.compute(...)` in `LapEvaluator.evaluate` on success.
- `MetricCollector` tracks the three new fields.
- `src/orchestrator/TestPhase11.luau` unit tests cover:
  - zero metrics → zero score
  - hang-time component saturates at `HANG_TIME_FULL_SCORE`
  - near-miss component is highest when airtime distance is just below the cap
  - chicane score is highest with large offsets to *both* sides
  - over-budget lap yields `over_budget = true`

No behaviour change for existing suites. Target: `phase11_unit` green; all prior
suites still green.

### 11b — HUD surfacing + single-sector challenge-up
- UIState exports `publishScore(score)`. HUD shows per-sector score when a job
  commits.
- `JobRunner` invokes Stage B when request qualifiers include `"extreme"` or on
  `/demo extreme`.
- Add `phase11_integration` that runs a `extreme jump in sector 3` request and
  asserts `score.air > 0` and `score.total` is strictly greater than a `jump`
  without the qualifier.

Current branch status:

- implemented
- `UIState.publishScore(...)` publishes per-sector score attributes
- HUD client reads the score state
- `extreme` requests invoke `ChallengeRunner.runUp(...)`
- `phase11_integration` currently asserts successful extreme commit plus score publication

### 11c — Maximiser campaign
- Add `src/orchestrator/MaximizerAgent.luau`.
- `/demo maximize` wires it. Reuses `JobRunner.submit` internally so the single-
  sector guarantees are preserved.
- Budget eviction loop runs **after** all sectors have been submitted, not
  inline — keeps the watch narrative linear.

Current branch status:

- implemented
- fixed six-step campaign remains in place
- campaign retains per-sector committed scores rather than only reading the last HUD score
- final whole-track budget probe now runs after the pass
- lowest-score sectors are flattened and re-probed until the track returns under budget or no scored sectors remain
- HUD state now publishes `track_score_total`, `track_score_count`, `track_budget_used`, `track_budget_headroom`, and `track_over_budget`

### 11d — Score-driven proposer tuning
- `MinimalProposer.escalate(...)` reads the **EscalationLadder** and picks the
  lever most likely to raise the limiting score component.
- Re-tune `QUALIFIER_BIASES` so `extreme` pushes further than `really`.
- Regression pass: confirm `/demo crest` still commits in ≤3 attempts and
  `phase9_integration` still passes.

Current branch status:

- partially implemented
- `extreme` now biases the initial proposal harder for all three mechanics
- Stage B lever choice is still driven by the current `ChallengeScore.suggestEscalation(...)` heuristic rather than a richer per-mechanic ladder/search pass
- RampJump `no_progress` failures now repair as a takeoff-speed problem rather than lengthening the ramp uphill
- CrestDip and Chicane traversal softening now respect their integrity minima, preventing repair-induced integrity-failure loops
- failure-detail observability is now threaded through `FailureDetector` → `JobRunner` / `MaximizerAgent` traces → `LapEvaluator.buildFailurePacket(...)`

## 6. Open questions

- **Mechanic fairness:** should each mechanic have its own score ceiling, or
  should they compete directly? If competing, expect the agent to place only
  chicanes (they score well on both lateral and time-cost). Mitigation:
  per-mechanic weights or `track_score` with a diversity multiplier.
- **Per-sector baseline time:** today we only measure whole-lap time. For score
  component `time_cost` we approximate with `sector_exit_speed` drop. True
  per-sector timing would require sector-entry/exit timestamps in
  MetricCollector — small change, added in 11b.
- **Near-miss for CrestDip vs "airborne too long":** the current preflight
  rejects over-cap airtime immediately. We want to *reward* getting close to
  the cap without crossing it. The score component uses `airtime_distance /
  CRESTDIP_MAX_AIRTIME_DISTANCE` as the margin signal, which is well-defined
  even though the verifier terminates at the cap.

## 7. Risks

1. **Weights are a design surface, not a given.** First-pass numbers in
   Constants are guesses. Expect one or two live-Studio retune passes after
   `/demo maximize` runs for the first time.
2. **Budget can trivialise the track.** If `CHALLENGE_BUDGET_RATIO` is too
   tight, the maximiser evicts everything interesting. Start at 0.5; widen to
   0.75 if eviction is happening every run.
3. **Challenge-up can drift score without improving feel.** A hill-climb over a
   noisy fitness function is just noise. Guard: require `score.total` to
   improve by at least `MIN_ESCALATION_DELTA = 0.25` or the mutation is
   discarded.
4. **Near-miss depends on the verifier's semi-rail stability.** If the
   semi-rail changes, score weights need to move with it. Flag in
   `agent-handoff.md` when touching `VerifierController`.
5. **Adding fields to `RunMetrics` is an `AttemptRecord`/`FailurePacket`
   schema fan-out.** All three of those serialisations already tolerate extra
   fields (they are plain tables), but integration tests that deep-compare
   tables need a selective comparator. Phase 11a prototypes use `T.expect`
   which is field-by-field, not equality.

## 8. Files that will change

**11a (this branch):**
- `src/integrity/ChallengeScore.luau` — new
- `src/common/Types.luau` — new fields / type
- `src/common/Constants.luau` — new constants
- `src/verifier/MetricCollector.luau` — new telemetry
- `src/integrity/LapEvaluator.luau` — compute score on success
- `src/orchestrator/AttemptRunner.luau` — propagate score (no-op if nil)
- `src/orchestrator/TestPhase11.luau` — new
- `src/orchestrator/TestDispatcher.luau` — phase11 branches
- `tools/test_bridge_config.json` — phase11 entries
- `Makefile` — phase11 targets

**11b:**
- `src/orchestrator/JobRunner.luau`
- `src/orchestrator/UIState.luau`
- `src/client/HUD.client.luau`
- `src/ui/StatusPanel.luau`
- `src/orchestrator/MinimalProposer.luau` — `escalate`
- request parser / qualifier list for `extreme`

**11c:**
- `src/orchestrator/MaximizerAgent.luau` — new
- `JobRunner.submit` `/demo maximize` case

**11d:**
- Proposer weight retune, qualifier retune, regression suite.

## 9. Verification plan

Minimum set after 11a:
- `make phase11_unit` green
- `make phase10_integration` still green
- `make phase9_integration` still green
- `make phase4` still green

Full set after 11d:
- All of the above
- `make phase11_integration` green
- Live `/demo maximize` lap, recorded in handoff with:
  - final `track_score`
  - committed mechanics per sector
  - `budget_used`
  - whether eviction fired

## 10. Concrete scoring math (v1)

Written here so the next agent does not have to reverse-engineer it from the
Luau source. All components are clamped to `[0, 10]`.

```
air        = clamp01(hang_time / HANG_TIME_FULL_SCORE) * 10
lateral    = clamp01(peak_lateral_g / LATERAL_G_FULL_SCORE) * 10
near_miss  = near_miss_component(state, metrics) * 10     -- see below
time_cost  = clamp01((slowdown_ratio - 1) / CHALLENGE_BUDGET_RATIO) * 10
total      = W_AIR * air + W_LATERAL * lateral + W_NEAR_MISS * near_miss
           - W_TIME * time_cost
```

Near-miss per mechanic (all return `[0, 1]`):
```
RampJump:
  margin_reacquire = 1 - clamp01((RAMPJUMP_REACQUIRE_MAX - reacquire_distance)
                                  / (RAMPJUMP_REACQUIRE_MAX * NEAR_MISS_ZERO_AT_MARGIN))
  return margin_reacquire

CrestDip:
  margin_airtime = clamp01(target_airtime_distance / CRESTDIP_MAX_AIRTIME_DISTANCE)
  return margin_airtime

Chicane:
  corridor_half = corridor_width / 2
  margin_wall = 1 - clamp01((corridor_half - max(target_left_offset, target_right_offset))
                             / (corridor_half * NEAR_MISS_ZERO_AT_MARGIN))
  return margin_wall
```

Budget flag:
```
over_budget = slowdown_ratio > 1 + CHALLENGE_BUDGET_RATIO
budget_used = clamp01((slowdown_ratio - 1) / CHALLENGE_BUDGET_RATIO)
```

If `over_budget`, the outer maximiser divides `track_score` by 2. Single-sector
jobs still commit (integrity passed) but are flagged in the HUD.

## 11. What is prototyped in this branch

See commits on `feature/phase11-challenge-rewards`:

- `plans/phase11.md` — this doc.
- `src/integrity/ChallengeScore.luau` — pure scoring function.
- `src/common/Constants.luau` — new score weights + budget ratio.
- `src/common/Types.luau` — `ChallengeScore` type + RunMetrics/RunResult
  additions.
- `src/orchestrator/TestPhase11.luau` — unit test skeleton (no Studio required;
  stateless scoring only in 11a).
- `src/orchestrator/TestDispatcher.luau` — `phase11_unit` branch.
- `tools/test_bridge_config.json` — `phase11_unit: skip_baseline`.
- `Makefile` — `phase11_unit` target.

Not yet wired (left to next agent):

- MetricCollector extension for `hang_time`, `peak_lateral_g`, `target_min_speed`
  (scaffolded as zero-valued defaults so the scoring function works on today's
  metrics).
- LapEvaluator invocation of `ChallengeScore.compute` on success.
- Any UI surface for the score.
- Stage B challenge-up loop.
- `/demo maximize`.

The point of shipping 11a alone is that the **scoring contract** is frozen and
testable before anyone writes a campaign agent against it.
