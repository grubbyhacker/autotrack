-- ActionValidator.luau
-- Validates structured output from the LLM before it enters the CI loop.
-- prd_plan.md §15.3, Phase 7
--
-- Rules:
--   - repair step must contain exactly one AgentAction
--   - SetNumericLever: lever must be in legal_actions.numeric_levers for the mechanic
--   - SetPad: pad must be "ingress" or "egress"; value must be "None"|"Boost"|"Brake"
--   - initial proposal must conform to SectorState schema

local Types = require(script.Parent.Parent.common.Types)
local LevelMappings = require(script.Parent.Parent.common.LevelMappings)

type AgentAction = Types.AgentAction
type SectorState = Types.SectorState
type Mechanic    = Types.Mechanic

local ActionValidator = {}

-- Validate an AgentAction against the legal actions for a mechanic.
-- Returns (true, nil) or (false, errorString).
function ActionValidator.validateAction(action: AgentAction, mechanic: Mechanic): (boolean, string?)
	if action.type == "SetNumericLever" then
		local legal = LevelMappings.NUMERIC_LEVERS[mechanic]
		if not legal then
			return false, "unknown mechanic: " .. mechanic
		end
		local found = false
		for _, lever in legal do
			if lever == action.lever then found = true; break end
		end
		if not found then
			return false, "lever '" .. action.lever .. "' not legal for " .. mechanic
		end
		if type(action.value) ~= "number" then
			return false, "lever value must be a number"
		end
	elseif action.type == "SetPad" then
		if action.pad ~= "ingress" and action.pad ~= "egress" then
			return false, "pad must be 'ingress' or 'egress'"
		end
		local valid = { None = true, Boost = true, Brake = true }
		if not valid[action.value] then
			return false, "pad value must be None, Boost, or Brake"
		end
	else
		return false, "unknown action type: " .. tostring((action :: any).type)
	end
	return true, nil
end

-- Validate a proposed SectorState (from initial proposal).
-- Returns (true, nil) or (false, errorString).
function ActionValidator.validateSectorState(state: SectorState): (boolean, string?)
	-- TODO: Phase 7 — check all required fields are present and within schema
	error("ActionValidator.validateSectorState: not yet implemented")
end

return ActionValidator
