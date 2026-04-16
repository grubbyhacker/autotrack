-- FailureDetector.luau
-- Watches for definitive run failures and terminates the run immediately.
-- prd_plan.md §6.5, §12, Phase 3
--
-- Failure classes:
--   mechanic_integrity_failure  — mechanic-specific integrity check failed
--   local_execution_failure     — car could not traverse the edited sector
--   downstream_failure          — car failed in a sector other than the edited one
--   system_failure              — timeout or unexpected runtime error

local Types = require(script.Parent.Parent.common.Types)
local Constants = require(script.Parent.Parent.common.Constants)

type FailureInfo = Types.FailureInfo

local FailureDetector = {}

-- Called each frame during a run.
-- Returns a FailureInfo if a definitive failure is detected, else nil.
-- elapsed: seconds since run start
-- currentSector: which sector the car is currently in (1-based straight index)
function FailureDetector.check(
	elapsed: number,
	currentSector: number
): FailureInfo?
	if elapsed >= Constants.LAP_TIMEOUT then
		return { type = "system_failure", sector_id = currentSector }
	end

	-- TODO: Phase 3/5 — check for:
	--   • car below world Y threshold (fell off)
	--   • car stopped / reversed beyond recovery
	--   • heading error exceeding recovery threshold
	return nil
end

return FailureDetector
