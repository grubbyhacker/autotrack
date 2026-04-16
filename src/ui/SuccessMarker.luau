-- SuccessMarker.luau
-- Brief highlight on the committed sector after a successful job.
-- prd_plan.md §13.4, Phase 8

local Constants = require(script.Parent.Parent.common.Constants)

local SuccessMarker = {}

-- Briefly highlight the committed sector, then fade out after UI_SUCCESS_DWELL seconds.
-- sectorParts: the Instances making up the sector geometry
function SuccessMarker.flash(sectorParts: { Instance })
	-- TODO: Phase 8 — SelectionBox highlight, then task.delay(Constants.UI_SUCCESS_DWELL, remove)
end

return SuccessMarker
