-- FailureMarker.luau
-- Visual marker placed at the failure point during analysis/repair phases.
-- prd_plan.md §13.3, Phase 8
--
-- Placed via MCP at the car's final position on failure.
-- Remains visible during all analysis and repair attempts.
-- Cleared on commit, revert, or new job start.

local FailureMarker = {}

-- Show the failure marker at a world position.
function FailureMarker.show(position: Vector3)
	-- TODO: Phase 8 — MCP: place a highlight part / SelectionBox at position
end

-- Hide and destroy the marker.
function FailureMarker.hide()
	-- TODO: Phase 8
end

return FailureMarker
