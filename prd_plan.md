# Roblox Autonomous Level-Design CI Pipeline — PRD + Schemas + Build Handoff

## Status

This is the consolidated handoff artifact for implementation with Claude Code or Codex.
It supersedes earlier partial working drafts and folds in all decisions made after the original source spec. The intent is to give a coding agent one durable markdown file containing product requirements, runtime constraints, schema contracts, architecture, and an implementation plan.

## One-line summary

A single AI agent modifies one straight sector at a time on a live rectangular Roblox track, then runs a visible end-to-end verifier-car simulation to decide whether that change should commit or revert, while preserving mechanic integrity and overall track solvability.

---

# 1. Product framing

## 1.1 What this is

This project is an **Autonomous Level-Design CI Pipeline**.

It is not a racing game. It is a **watchable simulation** showing:
- propose
- build
- verify
- fail
- analyze
- repair
- rerun
- commit or revert

The point is to make agentic inner-loop behavior visible.

## 1.2 What this is not

- Not a multiplayer game
- Not a player-driven driving experience
- Not procedural free-form track generation
- Not an invisible CI system with a fake replay
- Not a parallel multi-agent environment

## 1.3 Simulation assumptions

- There is exactly **one verifier car**
- Nobody else ever drives the track
- There is exactly **one live track**
- There is exactly **one running agent job at a time**
- The visible simulation is the real deciding simulation

---

# 2. Track model

## 2.1 Generator

The track is generated at runtime by a **parameterized rectangular generator**.

Inputs:
- `rows`
- `cols`

Default v1:
- `2 x 5`

## 2.2 Topology rules

The generator produces:
- full track topology
- fixed corner sectors
- editable straight sectors
- clockwise sector ordering
- entry/exit transforms for every sector
- canonical start state

## 2.3 Editable surface

- Only **straight sectors** are editable in v1
- Corners are fixed geometry
- Straight sectors are numbered clockwise from the canonical start

## 2.4 Straight sector length

- All straight sectors have **uniform fixed length** in v1

This keeps mechanic tuning and integrity thresholds stable.

## 2.5 Entry/Exit transforms

Each sector has:
- fixed **Entry** transform
- fixed **Exit** transform

Properties:
- generated at runtime
- aligned to **cardinal directions** only
- immutable during a job

The agent may modify only the interior of the sector, never the boundary transforms.

## 2.6 Canonical start state

Each run begins from a canonical start state before sector 1, with fixed:
- position
- heading
- speed/controller reset state

---

# 3. User interaction model

## 3.1 Input surface

- Single text box
- Plain text request

Examples:
- `Add a jump in sector 3`
- `Add a really tall and long jump with lots of air time in sector 4`
- `Add a chicane in sector 5`
- `Add a crest in sector 2`

## 3.2 Parsing requirements

A valid request must resolve to exactly:
- one sector
- one supported mechanic

The parser may use **light normalization** for obvious mechanic synonyms, while still rejecting ambiguity.

Examples of allowed normalization:
- `jump` -> `RampJump`
- `s-curve` -> `Chicane`
- `crest` or `dip` -> `CrestDip`

## 3.3 Qualifiers

Qualifiers are allowed in plain text.

Examples:
- `really tall`
- `tight`
- `long`
- `gentle`
- `lots of air time`

Behavior:
- qualifiers are **soft hints only**
- they bias the **initial proposal**
- they do not create measurable obligations
- they do not affect acceptance criteria

## 3.4 Strict rejection

Reject if:
- sector missing
- multiple sectors referenced
- unsupported mechanic
- ambiguous mechanic
- request targets more than one sector
- request is vague beyond recoverable normalization

---

# 4. Supported mechanics

v1 supports exactly three mechanic families.

## 4.1 RampJump

A geometry-only jump.

Agent-tunable levers:
- `ramp_angle`
- `ramp_length`
- `gap_length`
- `landing_length`
- `ingress pad`
- `egress pad`

Important v1 decision:
- **no obstacle system**
- jump integrity is based on geometry and kinematics only

## 4.2 Chicane

A geometry-only S-shaped high-curvature mechanic.

Agent-tunable levers:
- `amplitude`
- `transition_length`
- `corridor_width`
- `ingress pad`
- `egress pad`

Important v1 decision:
- **no explicit speed gate**
- integrity is enforced by geometry guardrails
- anti-crawl pressure comes from overall lap-time slowdown vs baseline

## 4.3 CrestDip

A geometry-only vertical mechanic covering both crest and dip behavior.

Agent-tunable levers:
- `height_or_depth`
- `radius`
- `sector_length`
- `ingress pad`
- `egress pad`

Important v1 decision:
- no airborne requirement
- must be reacquired on semi-rails before leaving the sector

---

# 5. Pads and corner behavior

## 5.1 Pad model

Pads are explicit visible tuning surfaces.

Each pad may be:
- `None`
- `Boost`
- `Brake`

Properties:
- fixed authored effect magnitude
- no arbitrary numeric strengths
- no stacking

## 5.2 Straight sectors

Each straight sector has:
- one ingress pad
- one egress pad

## 5.3 Corner sectors

Corners are:
- fixed geometry
- non-editable in v1
- allowed to have pads

Corner pads exist as part of committed track state, but the agent may **not** modify corner pads during v1 jobs.

---

# 6. Verifier model

## 6.1 Core policy

The verifier simulation must remain visible to the player because that is the point of the system.

Therefore v1 uses:
- **server-authoritative simulation**
- as deterministic as practical
- no hidden deciding reruns

## 6.2 Verifier car

There is exactly one canonical verifier car with fixed:
- size
- physics profile
- propulsion model
- guidance model

## 6.3 Semi-rail model

The verifier is **guided, not pinned**.

Intended control balance:
- strong forward motion control
- limited lateral correction
- limited orientation correction

This allows meaningful failures caused by geometry, speed, instability, or poor reacquisition.

## 6.4 Propulsion

Use a **continuous forward-speed controller**, not a one-time launch impulse.

## 6.5 Failure termination

- Immediate termination on first definitive failure
- No continuation to gather downstream failures after that point

---

# 7. CI / agent loop

## 7.1 High-level flow

1. Parse request
2. Validate request
3. Acquire global track lock
4. Agent produces initial proposal for the target sector
5. Apply working sector state
6. Run full-lap visible verifier simulation
7. Evaluate result
8. Commit on success, or enter repair loop on failure
9. Revert on retry exhaustion

## 7.2 Initial proposal

The initial proposal may set:
- all legal numeric mechanic levers
- ingress pad
- egress pad

Constraints:
- values must conform to schema only
- no other restrictions

## 7.3 Repair loop

After each failed run:
- agent receives structured diagnostics
- agent may change **exactly one lever**
- then simulation runs again

Budget:
- up to **5 repair attempts** after the initial proposal

## 7.4 Locality rule

The agent may only modify the targeted straight sector.

It may not modify:
- other straight sectors
- corner geometry
- corner pads
- neighboring sector geometry
- track topology
- sector entry/exit transforms

## 7.5 Verification scope

Even though edits are local, verification is always:
- **full-track**
- **end-to-end lap**

## 7.6 Commit / revert semantics

If the job succeeds:
- the sector state is committed to the live track (“Main”)

If the job fails after retry exhaustion:
- full revert of the targeted sector package to last committed state

Rollback must restore:
- geometry
- pads
- any sector-local authored state that was part of the working mutation

Mental model:
- failed attempt = rejected merge
- next request starts from clean committed Main

---

# 8. Track evolution and persistence

## 8.1 In-session accumulation

Accepted jobs accumulate within the session.

This means:
- current committed track state evolves over time
- future jobs build on prior successful changes

## 8.2 Cross-session persistence

v1 is **ephemeral**.

On restart:
- track resets
- stats reset
- baseline recomputes

---

# 9. Concurrency and admission

## 9.1 Single running job

Exactly one agent job may run at a time.

There is one live track, and it is not shareable across concurrent jobs.

## 9.2 Rejected submissions

If the track is busy:
- reject immediately
- do not queue
- do not count as failure
- do not include in stats

---

# 10. Baseline and performance pressure

## 10.1 Baseline

The system computes a clean-track baseline lap time **once per session**.

It is then cached for the rest of that session.

## 10.2 Slowdown

Track:
- baseline lap time
- current lap time
- slowdown ratio / percentage

## 10.3 Role of slowdown

Slowdown is a **soft optimization pressure**, not a hard gate.

This helps discourage over-braking or trivializing the track without hiding real long-term degradation.

---

# 11. Mechanic integrity

## 11.1 General rule

A candidate is accepted only if:
1. full-lap run succeeds
2. the edited sector still qualifies as the requested mechanic

This is the **mechanic integrity gate**.

## 11.2 RampJump integrity

A valid RampJump must satisfy:
- `gap_length >= 2` (minimum gap guardrail)
- verifier becomes airborne
- air distance exceeds minimum threshold
- landing occurs inside a valid landing zone
- semi-rail reacquisition occurs within threshold after landing

No obstacle-clearance requirement exists in v1.

## 11.3 Chicane integrity

A valid Chicane must satisfy geometry guardrails so it does not regress toward a straight.

Required properties include:
- at least two alternating lateral deflections
- minimum lateral displacement
- minimum curvature severity

No explicit per-sector speed gate exists in v1.

## 11.4 CrestDip integrity

A valid CrestDip must satisfy:
- minimum vertical displacement
- minimum vertical curvature
- successful traversal through the sector
- stable semi-rail reacquisition **before crossing the sector exit**

No airborne requirement exists in v1.

---

# 12. Failure model

High-level classes:
- `mechanic_integrity_failure`
- `local_execution_failure`
- `downstream_failure`
- `system_failure`

Use diagnostics such as entry speed, exit speed, heading error, reacquisition state, and failure sector as hints, but not all of those are acceptance gates.

---

# 13. UI behavior

## 13.1 Visible status phases

Surface phases such as:
- `Analyzing failure...`
- `Applying repair...`
- `Running simulation...`
- `Committed`
- `Reverted`

## 13.2 Pacing

Use slight intentional delays between phases to make the loop legible:
- around 0.5–1.5 seconds

Do not artificially slow the physics simulation itself.

## 13.3 Failure visualization

On failure:
- stop immediately
- highlight failure point
- show verifier final position
- optionally show a short trajectory tail
- keep the marker visible during analysis/repair

## 13.4 Success visualization

On success:
- briefly highlight the modified sector
- show a clear success/commit state
- brief dwell before returning to idle

## 13.5 Explanations

Show only a **short action explanation** per repair step.

Examples:
- `Entry speed too high; added ingress brake`
- `Failed to reacquire; reduced crest height`
- `Jump undershot; increased ramp angle`

Do not expose long reasoning traces.

---

# 14. Agent model

## 14.1 Identity

v1 uses a **single default agent**.

## 14.2 Stochasticity

The agent may be stochastic.

The same request on the same committed track may produce different:
- initial proposals
- repair paths
- final outcomes

However, the runtime remains as deterministic as practical.

---

# 15. Schema contracts (normative)

## 15.1 Request

```json
Request {
  request_id: string,
  raw_text: string,
  parsed: {
    sector_id: int,
    mechanic: "RampJump" | "Chicane" | "CrestDip"
  },
  qualifiers: string[],
  timestamp: number
}
```

## 15.2 SectorState

```json
SectorState {
  sector_id: int,
  mechanic: "RampJump" | "Chicane" | "CrestDip",
  params: {
    ramp_angle?: int,
    ramp_length?: int,
    gap_length?: int,
    landing_length?: int,
    amplitude?: int,
    transition_length?: int,
    corridor_width?: int,
    height_or_depth?: int,
    radius?: int,
    sector_length?: int
  },
  pads: {
    ingress: "None" | "Boost" | "Brake",
    egress: "None" | "Boost" | "Brake"
  },
  version: int
}
```

## 15.3 AgentAction

```json
AgentAction =
  | {
      type: "SetNumericLever",
      lever: string,
      value: int
    }
  | {
      type: "SetPad",
      pad: "ingress" | "egress",
      value: "None" | "Boost" | "Brake"
    }
```

Constraints:
- initial proposal may set the full sector state
- repair step may apply exactly one action

## 15.4 RunResult

```json
RunResult {
  success: boolean,
  failure: {
    type: "mechanic_integrity_failure"
        | "local_execution_failure"
        | "downstream_failure"
        | "system_failure",
    sector_id: int
  } | null,
  metrics: {
    entry_speed: number,
    exit_speed: number,
    airborne: boolean,
    air_distance: number,
    lateral_error: number,
    vertical_displacement: number,
    reacquired: boolean,
    lap_time: number,
    slowdown_ratio: number
  }
}
```

## 15.5 FailurePacket

```json
FailurePacket {
  request: Request,
  sector_state: SectorState,
  attempt_index: int,
  last_action: AgentAction | null,
  run_result: RunResult,
  diagnostics: {
    failure_sector: int,
    hints: string[]
  },
  legal_actions: {
    numeric_levers: string[],
    pads: ["ingress", "egress"]
  }
}
```

## 15.6 CIJob

```json
CIJob {
  job_id: string,
  request: Request,
  initial_state: SectorState,
  working_state: SectorState,
  attempts: [
    {
      attempt_index: int,
      action: AgentAction | null,
      result: RunResult
    }
  ],
  final_status: "committed" | "reverted"
}
```

## 15.7 Runtime-owned integrity hooks

```json
RampJumpIntegrity {
  min_gap_level: 2,
  airborne: true,
  min_air_distance: number,
  landing_zone_hit: boolean,
  reacquire_distance_max: number
}
```

```json
ChicaneIntegrity {
  min_lateral_displacement: number,
  min_alternations: 2,
  min_curvature: number
}
```

```json
CrestDipIntegrity {
  min_vertical_displacement: number,
  min_curvature: number,
  reacquired_before_exit: boolean
}
```

---

# 16. Repo-first implementation stance

## 16.1 Rojo is required

Implementation should assume a **Rojo-based repo-first workflow**, not opaque direct mutation through the Roblox MCP server.

Rationale:
- coding agents can work in a normal git repo
- diffs are visible and reviewable
- project structure is stable
- changes are not trapped inside opaque Studio state

## 16.2 Implications for the implementation plan

The build should target:
- Roblox experience source kept in git
- Luau modules authored in repo
- Rojo project file as source of truth for sync into Studio
- coding agents should modify repo files, not rely on imperative Studio edits

## 16.3 Practical recommendation

Use Rojo for:
- source layout
- module boundaries
- deterministic rebuild/sync
- code review and branch-based iteration

Keep runtime/editor-only assets to a minimum.

---

# 17. Architecture and module plan

## 17.1 Recommended build order

### Phase 1 — Static skeleton
Build:
- track generator
- fixed corners
- numbered editable straights
- canonical start state
- global single-job lock
- baseline lap scaffold

Deliverable:
- flat baseline lap succeeds end to end

### Phase 2 — Sector package model
Build:
- sector registry
- sector serializer
- sector applier
- sector rollback

Deliverable:
- one sector can be replaced deterministically from schema data and reverted fully

### Phase 3 — Semi-rail verifier
Build:
- server-owned verifier car
- canonical reset
- forward speed controller
- lateral correction
- orientation correction
- failure termination
- reacquire detection

Deliverable:
- verifier reliably completes flat track and fails on intentionally impossible geometry

### Phase 4 — Mechanic builders
Build:
- RampJump builder
- Chicane builder
- CrestDip builder
- Pad builder

Deliverable:
- any legal SectorState can be rendered deterministically

### Phase 5 — Metrics and integrity evaluators
Build runtime evaluators for:
- RampJump
- Chicane
- CrestDip
- full-lap run

Deliverable:
- canonical RunResult and FailurePacket generation

### Phase 6 — CI orchestrator
Build the state machine:
- Idle
- ParseRequest
- RejectRequest
- AcquireTrack
- GenerateInitialProposal
- ApplyWorkingSector
- RunVerification
- EvaluateResult
- AnalyzeFailure
- ApplyRepair
- Commit
- Revert

Deliverable:
- one job runs end to end with visible transitions

### Phase 7 — LLM adapter
Build the narrow LLM boundary:
- initial proposal call
- repair-step call
- structured output validation

Deliverable:
- swappable Claude/Codex/mock agent backend

### Phase 8 — UI layer
Build:
- text input
- current status panel
- attempt count
- explanation string
- failure highlight
- success highlight
- session stats
- slowdown display

Deliverable:
- observer can understand the loop without logs

---

# 18. Suggested repo/module structure

```text
.
├── default.project.json
├── README.md
├── src
│   ├── common
│   │   ├── Types.luau
│   │   ├── Constants.luau
│   │   └── LevelMappings.luau
│   ├── track
│   │   ├── TrackGenerator.luau
│   │   ├── SectorRegistry.luau
│   │   ├── SectorSerializer.luau
│   │   ├── SectorApplier.luau
│   │   └── SectorRollback.luau
│   ├── mechanics
│   │   ├── RampJumpBuilder.luau
│   │   ├── ChicaneBuilder.luau
│   │   ├── CrestDipBuilder.luau
│   │   └── PadBuilder.luau
│   ├── verifier
│   │   ├── VerifierCar.luau
│   │   ├── VerifierController.luau
│   │   ├── ReacquireDetector.luau
│   │   ├── FailureDetector.luau
│   │   └── MetricCollector.luau
│   ├── integrity
│   │   ├── RampJumpIntegrity.luau
│   │   ├── ChicaneIntegrity.luau
│   │   ├── CrestDipIntegrity.luau
│   │   └── LapEvaluator.luau
│   ├── agent
│   │   ├── RequestParser.luau
│   │   ├── PromptBuilder.luau
│   │   ├── LLMAdapter.luau
│   │   └── ActionValidator.luau
│   ├── orchestrator
│   │   ├── JobRunner.luau
│   │   ├── JobStateMachine.luau
│   │   └── AttemptRunner.luau
│   └── ui
│       ├── StatusPanel.luau
│       ├── StatsPanel.luau
│       ├── FailureMarker.luau
│       └── SuccessMarker.luau
└── tests
    ├── parser
    ├── integrity
    ├── sector
    └── orchestrator
```

---

# 19. Recommended first milestone

Build a **no-LLM vertical slice first**.

Hardcode:
- one parsed request
- one initial proposal
- one repair policy

Why:
- proves physics
- proves rollback
- proves geometry generation
- isolates simulation risk from model risk

Milestone definition:
- submit one canned request
- mutate one sector
- visible run happens
- failure or success is detected correctly
- if failure, one repair rerun occurs
- commit or revert occurs correctly

Only after that should Claude/Codex be connected as the real agent.

---

# 20. Testing plan

## 20.1 Unit tests

- request parsing
- action validation
- level mapping validation
- sector serialization / rollback
- mechanic integrity evaluators

## 20.2 Simulation tests

- flat baseline lap succeeds
- impossible jump fails
- invalid chicane fails
- CrestDip without reacquire fails

## 20.3 System tests

- accepted request commits
- retry exhaustion reverts
- busy track rejects second request
- session restart resets all state

---

# 21. Main implementation risks

## Highest risk

Semi-rail tuning.

If guidance is too strong:
- mechanics become fake

If guidance is too weak:
- behavior becomes noisy and frustrating

## Other risks

- reacquire detection quality
- chicane geometry thresholds
- structured LLM output discipline
- visible pacing without sluggishness
- keeping Rojo/Studio sync predictable

---

# 22. Coding-agent guidance

When handing this to Claude Code or Codex, prefer these instructions:

1. Start with deterministic runtime pieces before LLM integration
2. Treat this markdown as normative
3. Do not invent new mechanics
4. Do not expand scope to multiplayer, queues, or hidden verification
5. Preserve repo-first Rojo workflow
6. Keep all structured contracts explicit in code
7. Fail fast on invalid request parsing or invalid agent output

---

# 23. Minimal next task for Claude Code / Codex

Implement, in order:
1. track generator (`rows x cols`, default `2 x 5`)
2. sector registry and numbering
3. baseline lap on flat track
4. sector replacement + full revert
5. verifier controller
6. one hardcoded RampJump builder
7. run evaluator and failure packet generation
8. CI state machine without LLM
9. then narrow LLM adapter

---

# 24. Source lineage

This consolidated artifact is derived from the original source spec and subsequent decisions in this conversation. The original uploaded spec remains the seed reference, but this document is the authoritative handoff going forward.
