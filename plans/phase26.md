# Phase 26 — Endurance Scoring HUD Simplification

## Summary

Redesign the endurance Session HUD cluster to remove per-sector scoring noise, prevent overlap, and make lap-level status readable at a glance. Keep `S`, `L`, `O` controls, keep `Base`, `Last`, and `%` together, and move per-sector values to Overview (`O`) mode as committed sector score annotations.

## Implementation Changes

### 1) Plan contract first

- Add canonical plan file `plans/phase26.md` before implementation.

### 2) Session HUD content + layout

- Replace the current multi-line per-sector score block (`Score/Air/Edge/Lat/Cost`) with a compact lap-level block:
  - `Base` (baseline lap time)
  - `Last` (latest committed full-lap time only)
  - `%` (delta vs baseline using committed full-lap values)
  - `Track` (total committed track score)
  - `Budget` (single-line `NN% · OK|OVER`, no bar)
- Reduce right rail width and reflow `Last` to its own row to avoid collisions.
- Keep `S`, `L`, `O` buttons in the Session cluster header row.

### 3) Public state/interface updates

- Add committed-lap UI state attributes (separate from generic latest-run attrs) so `Last/%` are stable and commit-authoritative.
- Add per-sector committed score attributes (e.g., `sector_<id>_committed_score`) for Overview annotation.
- Keep existing attrs for backward compatibility; HUD reads new committed-lap/sector-score attrs.

### 4) Publisher logic updates

- Update commit-path publishing so committed full-lap attrs update only on authoritative commit-lap outcomes.
- Update score publishing to persist committed sector score for the target sector.
- Ensure endurance track summary attrs (`track score`, `budget used/over`) are fed from committed track intent, not isolated-stage runs.

### 5) Overview (`O`) per-sector display

- Extend sector labels to support score annotation around sector name.
- In Overview mode, show committed sector score above sector label in green glow style.
- Hide score annotation outside Overview mode.
- Do not show per-sector values in Session HUD.

## Test Plan

- Add `src/orchestrator/TestPhase26.luau` with focused assertions for:
  - committed-lap attrs update only on committed full-lap publish path
  - isolated/non-committed publish paths do not overwrite committed `Last/%` source
  - per-sector committed score attrs update on score publish
  - track budget summary attrs remain commit-authoritative
- Wire suite through project test contract:
  - `src/orchestrator/TestDispatcher.luau`
  - `tools/test_bridge_config.json`
  - `Makefile` (`phase26` target and `make test-list` visibility)
- Run:
  - `make test TEST=phase26`
  - `make boot_smoke`
  - `make refactor_fast`

## Assumptions and Defaults

- "Baselap speed / Last committed lap speeds with +/-%" is implemented as lap-time values (`Base`, `Last`, `%`), consistent with current HUD semantics.
- Keep lap-level extras in Session as `Track` + `Budget` only.
- Budget presentation uses plain percent+state text (`OK`/`OVER`) without bar graphics.
- Overview per-sector value is committed sector score only (no second per-sector value line in Phase 26).
