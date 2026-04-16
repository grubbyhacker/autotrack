-- SectorRoundtrip.spec.luau
-- Tests sector serialisation, apply, and full rollback.
-- prd_plan.md §20.1

-- TODO: Phase 2 — test cases:
--   serialize then clone → deep equality
--   apply then revert → sector geometry matches original committed state
--   commit updates registry
--   revert on missing committed state → error
