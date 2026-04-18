# ADR — Phase 11 Scoring And Reporting

## Status

Accepted

## Context

Phase 11 introduced `ChallengeScore`, but the live HUD only exposed a compressed
sector total and track total. That made the scoring hard to interpret during
`/demo maximize`, even though the model itself was behaving correctly.

We need two things:

1. A stable statement of what the scoring model means
2. A minimal player-facing reporting format that explains score without adding
   visible clutter

## Decision

### 1. Canonical scoring explanation

The scoring model is described in plain language as:

- `Air`
  Rewards airtime and hang time
- `Lateral`
  Rewards side load and left-right aggression
- `Edge`
  The HUD/player-facing name for the internal `near_miss` term
  Rewards getting close to a mechanic’s failure boundary without failing
- `Cost`
  The slowdown penalty term

The total score is a weighted combination of:

`Air + Lateral + Edge - Cost`

This is intentionally a player-facing simplification of the exact implementation
in `src/integrity/ChallengeScore.luau`.

### 2. HUD wording

The HUD must stay minimal. The score rail should show:

- sector total
- component breakdown using the short names `Air`, `Lat`, `Edge`, `Cost`
- track total plus budget usage/headroom

The HUD should not attempt to explain formulas, weights, or per-mechanic details.
Those belong in docs, not the live overlay.

### 3. Developer-facing contract

The authoritative technical implementation remains:

- `src/integrity/ChallengeScore.luau`
- `src/common/Constants.luau`
- Phase 11 plan / handoff documents

This ADR exists to preserve the human-readable interpretation of the score and
the intended wording used in the HUD.

## Consequences

### Positive

- Demo viewers can understand why a sector scored well
- The UI stays compact
- Future agents have a stable naming contract for score reporting

### Negative

- The HUD uses the word `Edge` while the code uses `near_miss`
- This introduces one extra terminology mapping that must remain documented

## Notes

- `Edge` was chosen instead of `Near Miss` in the HUD because it is shorter and
  reads more cleanly in a compact score block.
- If the score model changes later, update both this ADR and the handoff.
