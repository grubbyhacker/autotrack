-- StatusPanel.luau
-- Displays the current CI phase, attempt count, and short explanation string.
-- prd_plan.md §13.1, §13.2, §13.5, Phase 8

local StatusPanel = {}

-- Update the displayed phase label.
-- phase: human-readable string, e.g. "Running simulation..."
function StatusPanel.setPhase(phase: string)
	-- TODO: Phase 8 — update the ScreenGui TextLabel
end

-- Update attempt counter display.
function StatusPanel.setAttempt(current: number, max: number)
	-- TODO: Phase 8
end

-- Display a short one-line explanation of the last repair action.
-- e.g. "Entry speed too high; added ingress brake"
function StatusPanel.setExplanation(text: string)
	-- TODO: Phase 8
end

-- Clear the explanation line.
function StatusPanel.clearExplanation()
	StatusPanel.setExplanation("")
end

return StatusPanel
