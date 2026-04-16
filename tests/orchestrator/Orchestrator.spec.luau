-- Orchestrator.spec.luau
-- System-level tests for the CI job runner.
-- prd_plan.md §20.3

-- TODO: Phase 6 — test cases:
--   accepted request commits sector and updates registry
--   retry exhaustion reverts sector to last committed state
--   concurrent submission while busy → immediate rejection, not counted as failure
--   session restart → all state reset, baseline recomputed
