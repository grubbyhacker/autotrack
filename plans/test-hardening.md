# Test Hardening Plan

## Goal

Harden the automated test surface before a round of mechanic tuning and cleanup work:

- remove stale or misleading test entry points
- add fast gates for refactor feedback
- keep mechanic regressions covered by explicit behavioral invariants
- preserve the maintained `make` + Studio bridge workflow

## Problems To Fix

1. The public suite contract is stale.
   - `Makefile` and `tools/test_bridge_config.json` still advertise removed suites (`phase7*`, `phase8*`, `phase10*`, `phase12`).
   - `src/orchestrator/TestDispatcher.luau` is now the real source of executable suites, so this drift should be eliminated and checked automatically.

2. The repo still carries dead test files.
   - `src/test/` is not mapped by Rojo and is an obsolete pre-bridge test surface.

3. Tune coverage is too coarse.
   - `phase21` mixes fast contract checks and slower live `/tune` lifecycle checks, which makes tune refactors harder to validate quickly.

4. The fast feedback story is weak.
   - There is no maintained “run the important cheap checks in one Studio boot” command.

5. Sector-completeness coverage is uneven.
   - RampJump already asserts runout reaches the sector exit.
   - Chicane and CrestDip need equally explicit automated checks for the sector-completeness invariant.

## Planned Changes

### 1. Suite-surface cleanup

- Remove stale suite targets from:
  - `Makefile`
  - `tools/test_bridge_config.json`
- Update maintained docs/examples that still point at removed suites:
  - `AGENTS.md`
  - `docs/local-test-runner.md`

### 2. Static contract check

- Add a fast local script that verifies the maintained suite contract is aligned across:
  - `src/orchestrator/TestDispatcher.luau`
  - `tools/test_bridge_config.json`
  - `Makefile`
- Expose it as:
  - `make test-contracts`

This should catch future suite drift without requiring Studio.

### 3. Faster tune validation

- Split `TestPhase21` into:
  - `phase21_unit` for fast tune-lab contracts
  - `phase21_integration` for live `/tune` lifecycle behavior
  - keep `phase21` as the full combined gate

### 4. Fast aggregate gate

- Add a maintained skip-baseline aggregate suite:
  - `refactor_fast`
- It should run the core cheap/high-signal unit-style suites in one Studio boot.

Candidate contents:
- `boot_smoke`
- `phase4_5_geometry`
- `phase5_unit`
- `phase6_unit`
- `phase9_unit`
- `phase11_unit`
- `phase13_unit`
- `phase14_unit`
- `phase14_5`
- `phase19`
- `phase20`
- `phase21_unit`

### 5. Mechanics regression aggregate

- Add a maintained baseline aggregate suite:
  - `mechanics_regression`
- It should cover the tuning-sensitive gameplay checks in one Studio boot.

Candidate contents:
- `phase4`
- `phase15`
- `phase16`
- `phase18`
- `phase21_integration`
- `phase21_experiment`

### 6. Missing mechanic invariants

- Add explicit sector-completeness assertions for:
  - Chicane
  - CrestDip

These tests should assert that the authored sector path still reaches the sector exit / sector boundary after the mechanic geometry ends.

## Verification Plan

### Static

- `make test-contracts`
- `make test-list`

### Fast Studio gate

- `make refactor_fast`

### Mechanics Studio gate

- `make mechanics_regression`

### Focused tune checks

- `make phase21_unit`
- `make phase21_integration`
- `make phase21_experiment`

## Expected Outcome

- One maintained static contract check
- One maintained fast refactor gate
- One maintained mechanics regression gate
- No dead/stale public suite entries
- Explicit sector-completeness coverage for every relevant straight-sector mechanic
