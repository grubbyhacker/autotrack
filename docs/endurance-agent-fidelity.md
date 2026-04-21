# Endurance Agent Fidelity Notes

## Purpose

This note captures the rationale from a design discussion about the current endurance-mode agent architecture, why it feels low-fidelity as an agent simulation, and the proposed direction for improving it.

This is intended to serve two purposes:

- design input for a future implementation pass
- source material for an article about the exercise and its lessons

## Current System

Today, endurance mode uses three distinct roles around the LLM boundary:

1. `orchestrate`
   Chooses the next high-level experiment for the track.
2. `propose`
   Generates a full `SectorState` for one requested mechanic in one sector.
3. `repair`
   Revises the failed proposal after simulation feedback.

In the current implementation, that flow is:

1. The orchestrator sees endurance-track context and returns a structured decision:
   - `sector_id`
   - `mechanic`
   - `params_hint`
   - or `action = "begin_loop"`
2. The server converts that structured decision into a short English request string such as:
   - `add an extreme jump in sector 7`
3. That string is fed back through the normal `JobRunner.submit(...)` path.
4. The request parser turns the string back into a structured request.
5. The proposer receives that parsed request and generates a full `SectorState`.
6. If the run fails, the repair agent receives the current local failure packet and revises the state.

## Important Clarification: "String Roundtrip"

The phrase "string roundtrip" refers only to a local server-side conversion:

- structured orchestrator decision
- converted into English request text
- parsed back into structured request data

This is **not** an additional LLM call, so it does **not** add token cost by itself.

The real paid LLM calls are still:

- one call for orchestration
- one call for proposal
- zero or more calls for repair

So there are two distinct concerns:

- local inefficiency: structured decision -> text -> structured request
- token inefficiency: multiple LLM calls for one endurance decision path

## Why The Current Setup Feels Low-Fidelity

The current architecture is clean, but as an agent simulation it feels underwhelming.

The issue is not simply that there are multiple roles. The issue is that the intent continuity between the roles is weak.

### What the orchestrator knows

The orchestrator gets a real track-level planning context:

- editable sectors
- current committed mechanic and params per editable sector
- sector scores
- slowdown budget usage
- whether the track is over budget
- attempt budget usage
- last result
- recent attempt history
- repeat pressure
- track intent summary

In plain language, it can reason about:

- what the track currently looks like
- what has already been tried
- what succeeded or failed recently
- which sectors or patterns are being overused
- whether the track is getting too slow
- whether the campaign should keep building or switch to live looping

### What the proposer knows

The proposer gets a much narrower, job-local brief:

- target sector
- target mechanic
- qualifiers from the request
- legal numeric levers for that mechanic
- default values
- min/max lever bounds
- allowed pad values
- schema/rules for what must be returned

In plain language, it can reason about:

- what kind of mechanic to build
- which knobs it is allowed to move
- how aggressive the request sounds
- the hard numeric/legal constraints

It does **not** get the orchestrator's full planning context.

### What the repair agent knows

The repair agent gets the richest local failure context:

- current sector state
- latest run result
- diagnostics
- legal actions or state-revision path
- capped recent job history for the same job

In plain language, it can reason about:

- how the current mechanic failed
- what signals suggest making it easier
- what happened in recent attempts on this same job

But it does **not** strongly inherit the orchestrator's original track-level intent.

## The Core Problem

The three agents do not share a durable design brief.

That means:

- the orchestrator acts more like a suggester than a director
- the proposer acts more like a translator than a downstream designer with intent continuity
- the repair agent acts more like a local optimizer than a preserving editor

This produces a "telephone game" effect:

1. the orchestrator picks a sector and mechanic with some vague hint
2. that intent gets compressed into a simple request string
3. the proposer invents local geometry from a much thinner brief
4. the repair agent then modifies that geometry based on failure feedback
5. over time, the final committed mechanic may drift far away from what the orchestrator actually wanted

## Why This Matters

If the goal is simply "make something work," the current system is serviceable.

If the goal is to simulate multiple cooperating agents in an interesting and legible way, the current setup is not enough.

A higher-fidelity agent simulation should make it legible that:

- the orchestrator had a strategic intent
- the proposer understood and implemented that intent locally
- the repair agent tried to preserve that same intent while fixing failures

Right now, that continuity is weak.

## The Missing Piece: Shared Design Intent

The proposed fix is **not** necessarily to collapse all roles into one LLM call.

The cleaner direction is:

- keep the roles separate
- introduce a shared structured design-intent object
- pass that same design intent into proposal and repair

That would let the roles remain distinct while still feeling like parts of one coherent decision chain.

## What Shared Design Intent Should Do

The orchestrator should be able to express more than:

- sector
- mechanic
- vague params hint

It should be able to express target outcomes and tradeoffs.

The proposer should then use that design intent to generate local geometry.

The repair agent should receive the same intent and preserve it while making the mechanic passable.

## Candidate Fields For A Shared Design Intent Object

The exact schema can be debated later, but a good first version likely needs fields like:

- `sector_id`
- `mechanic`
- `params_hint`
- `rationale`
- `target_score_band`
  - example: low / medium / high / extreme
- `target_budget_tolerance`
  - example: low / medium / high
- `target_reliability`
  - example: conservative / balanced / risky
- `spectacle_priority`
  - example: low / medium / high
- `novelty_priority`
  - example: low / medium / high
- `replacement_intent`
  - example: preserve current good sector unless projected gain is significant
- `desired_feel`
  - freeform but short
  - examples:
    - "big airtime but still recoverable"
    - "tight technical chicane with minimal slowdown"
    - "dramatic crest with moderate risk"
- `constraints`
  - short list of explicit constraints the downstream agent should preserve
  - examples:
    - "do not overrun slowdown budget"
    - "prefer ingress braking over egress braking"
    - "preserve downstream stability"

## Why This Is Better

With a shared design-intent object:

- the orchestrator becomes a true strategic director
- the proposer becomes a true local designer
- the repair agent becomes a preserving editor

That is a much more convincing multi-agent simulation than the current setup.

It also improves legibility for humans:

- the current intent can be inspected directly
- the proposal can be compared against the intended design brief
- the repair can be judged by whether it preserved or abandoned the brief

## What Is Lost Today

The current endurance path strips away too much information between orchestration and proposal.

What survives today:

- sector
- mechanic
- a small qualifier vocabulary inferred from `params_hint`

What is effectively lost today:

- why the orchestrator chose this candidate
- what score ambition it had in mind
- how much budget risk was acceptable
- whether novelty mattered more than raw score
- how much repair complexity was acceptable
- any durable notion of intended "feel"

This is why the proposer can easily generate something that technically matches the request but does not feel like a faithful implementation of the orchestrator's original idea.

## Design Direction

The likely best design direction is:

1. keep orchestration separate from proposal
2. remove the thin request-string bounce as the main handoff mechanism
3. introduce a structured design-intent handoff object
4. let proposal consume that object directly
5. let repair consume that same object along with the failure packet

That would preserve code cleanliness and role separation while materially improving agent fidelity.

## Short Summary

Today:

- the architecture is clean
- the roles are separate
- but the continuity of intent across roles is weak

The result:

- orchestrator feels like a suggester
- proposer feels like a translator
- repair feels like a local optimizer running without enough original design intent

The fix:

- add a shared structured design-intent object
- pass it from orchestrator to proposer to repair
- make all downstream steps preserve and act on that same intent

That would make endurance mode feel much more like a genuine multi-agent design system and much less like a relay race of loosely coupled prompts.

## Addendum: Agentic Memory Within The Simulation

Another important design direction is memory.

This memory should remain strictly **inside the simulation**:

- no persistence across sessions
- no out-of-band long-term storage
- no hidden memory layer outside the visible run

That constraint is important to the spirit of the project. The agents should appear to learn during the simulation, not across unrelated sessions.

### Current Memory Posture

Today:

- the orchestrator has bounded campaign memory within endurance mode
- the repair agent has bounded local job memory within one repair loop
- the proposer has almost no meaningful memory

This is one reason the proposer feels weak. It does not accumulate its own lessons from prior proposals and their outcomes, even though that is exactly the sort of short-horizon experiential memory that would make it feel more like a real agent.

At a minimum, the proposer should have access to:

- its previous proposals
- whether those proposals committed or reverted
- compact summaries of why they succeeded or failed

### Handoff Memory As A First-Class Concept

A promising model is to give agents explicit handoff-style memory, similar in spirit to the repository's own handoff documents.

The idea is not just to remember events, but to remember **interpretations**.

For example, an agent could be asked to append a short note answering prompts like:

- What have you learned?
- What should the next step know?
- What will make your work faster next time?

This makes the system more legible and more interesting. It turns the agent chain from a sequence of isolated prompts into a visible process of accumulating working knowledge.

### Why Free Text Alone Is Not Enough

The right direction is **not** to rely entirely on free-text diary entries.

Free text is useful, but it drifts easily:

- agents omit important facts
- agents overgeneralize
- agents store low-value commentary
- agents can become confidently wrong

So the memory design should have two layers:

1. structured memory
   - proposals
   - outcomes
   - scores
   - failure signatures
   - repair counts
   - other stable telemetry
2. bounded free-text handoff memory
   - what the agent thinks mattered
   - what it learned
   - what the next step should pay attention to

The structured layer keeps the system grounded. The free-text layer makes it feel agentic and interpretable.

### Shared Memory And Scoped Memory

The best shape is likely a combination of:

- shared run memory
- agent-local memory

Shared run memory should contain things that all agents ought to inherit, such as:

- the durable design intent
- major outcomes
- major learned constraints
- important track-level lessons discovered during the run

Agent-local memory should contain what is most useful to each role:

- orchestrator notebook
  - campaign strategy
  - overused patterns
  - budget/risk lessons
- proposer notebook
  - what proposal shapes have worked or failed
  - mechanic-specific local design lessons
- repair notebook
  - what repair moves have been effective
  - what failure signatures tend to imply

This gives both continuity and specialization.

### Append-Only Is Safer Than Free Rewriting

If agents can freely rewrite old memory entries, the system risks self-delusion:

- bad conclusions get polished into "truth"
- historical context gets erased
- memory becomes less auditable

The safer default is:

- append short notes
- keep a fixed-size ring buffer
- drop the oldest entries when full

If compaction is desired later, it should be explicit:

- summarize older entries into one compressed note
- preserve that compaction as another visible memory event

That keeps the memory bounded while still allowing self-healing.

### Letting Agents Choose What To Store

There is real value in letting agents decide what is worth remembering.

That can improve both:

- cost control
- relevance

If every turn is stored mechanically, memory will quickly become noisy.

If agents are allowed to decide whether a step produced a meaningful lesson, memory can stay compact and useful.

That said, this should happen within guardrails:

- current telemetry should outrank memory
- structured facts should outrank free-text notes
- free-text notes should be advisory, not authoritative

In other words:

- memory is interpretation
- telemetry is evidence

The system should not allow a free-text note like "tight chicanes always fail" to outweigh the actual current metrics and observed outcomes.

### Recommended Shape For A Memory Entry

A good first memory-entry schema would be small and explicit, for example:

- `author`
- `scope`
- `note`
- `confidence`
- `timestamp`

Possible scopes:

- `shared`
- `orchestrator`
- `proposer`
- `repair`

Each note should stay short. The goal is not essay writing. The goal is to record high-value working knowledge.

### The Conceptual Upgrade

Right now, the system mostly remembers events.

The proposed upgrade is to let it also remember interpretations.

That is a meaningful jump in agent fidelity.

It would make the agents feel less like prompt wrappers and more like entities that accumulate working knowledge inside the simulation.

### Recommended Milestone Direction

For a future agent-upgrade milestone, the recommended direction is:

1. preserve the current structured histories
2. add a bounded shared design-intent object
3. add bounded shared and agent-local handoff memory
4. make the proposer a real consumer of prior proposal outcomes
5. make repair preserve both current evidence and prior intent
6. keep all memory ephemeral and session-local

This would improve:

- agent continuity
- simulation legibility
- design fidelity
- human inspectability

without violating the project's constraint that learning should happen only within the live run.

## Further Considerations

The ideas above are strong, but some adjacent design questions should also be captured now even if they are deferred beyond a first implementation pass.

These may be too much for a strict v1, but they are important to keep in view while designing an agent-upgrade milestone.

### 1. Memory Ownership And Write Permissions

If the system has both shared and agent-local memory, it should define who is allowed to write to which memory surfaces.

For example:

- orchestrator writes to:
  - shared run memory
  - orchestrator-local memory
- proposer writes to:
  - proposer-local memory
  - shared memory only under stricter rules, if at all
- repair writes to:
  - repair-local memory
  - shared memory only under stricter rules, if at all

Without clear ownership, shared memory can become a noisy dumping ground.

### 2. Source Attribution For Memory

Memory entries should record not only what was written, but where the lesson came from.

For example, entries may want fields like:

- `source_type`
  - observed result
  - inferred pattern
  - downstream warning
  - explicit policy
- `source_ref`
  - attempt index
  - sector id
  - failure signature

This helps distinguish:

- a measured observation
from
- an agent's interpretation

That distinction matters for trust.

### 3. Positive Memory As Well As Negative Memory

The system should not only remember failures.

It should also remember successful patterns, for example:

- proposal shapes that committed cleanly
- repair moves that reliably stabilized a mechanic
- combinations of pads and params that preserved spectacle without blowing budget

Otherwise the system learns only what to avoid, not what to reuse.

### 4. Memory Expiry And Invalidation

A ring buffer helps with size, but not with stale beliefs.

Some notes may need to decay or lose relevance when the situation changes.

Examples:

- a note tied to a sector may become stale after that sector is overwritten
- a note tied to a design intent may become stale once the run's priorities shift
- old advice may deserve less weight after many later decisions

This is important for keeping memory useful rather than sticky.

### 5. Distinguish Facts, Heuristics, And Commitments

Not all memory entries should be treated the same way.

A useful distinction is:

- fact
  - observed result
- heuristic
  - inferred rule or pattern
- commitment
  - deliberate design priority or policy for the current run

Examples:

- fact: sector 7 reverted twice
- heuristic: extreme crests tend to overshoot budget late in the run
- commitment: preserve downstream stability over spectacle for this run

These are different categories and should not be mixed casually.

### 6. Handoff Acceptance, Not Just Handoff Creation

Cooperation is not just about what one agent writes. It is also about what the next agent accepts, ignores, or revises.

It may be valuable for downstream agents to explicitly indicate:

- what prior intent or memory they accepted
- what they ignored
- why

That would make cooperation much more legible.

### 7. Memory Budget By Role

Not every agent needs the same amount of memory.

A better design may budget memory differently by role:

- orchestrator: more campaign memory
- proposer: moderate design memory
- repair: denser but shorter local iterative memory

That is likely better than one uniform buffer size across all roles.

### 8. Visible Failure To Cooperate

If a downstream agent drifts away from prior intent, that should be visible rather than hidden.

Examples:

- proposer produced low-spectacle geometry despite high-spectacle intent
- repair made a mechanic safe but destroyed the intended feel

A small intent-drift indicator may be useful:

- preserved
- softened
- abandoned

This would help both debugging and presentation.

### 9. Structured Comparison Between Intended And Produced Design

Once shared design intent exists, it may be worth comparing:

- intended score ambition vs produced geometry
- intended reliability vs produced risk
- intended feel vs chosen params and pads

Without some comparison surface, the handoff remains mostly rhetorical.

### 10. Human Readability As A First-Class Requirement

Because the project is a watchable simulation, memory should not only be useful to the next model.

It should also be readable by a human observer.

That means asking:

- can a person understand the memory quickly?
- can a person tell whether it was useful?
- can a person see how one agent influenced the next?

This requirement should shape both the memory schema and the inspection tooling.
