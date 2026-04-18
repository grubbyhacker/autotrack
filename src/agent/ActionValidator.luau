-- ActionValidator.luau
-- Validates structured output from the LLM before it enters the CI loop.
-- prd_plan.md §15.3, Phase 7
--
-- Rules:
--   - repair step must contain exactly one AgentAction
--   - SetNumericLever: lever must be in legal_actions.numeric_levers for the mechanic
--   - SetPad: pad must be "ingress" or "egress"; value must be "None"|"Boost"|"Brake"
--   - initial proposal must conform to SectorState schema

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))

type AgentAction = Types.AgentAction
type SectorState = Types.SectorState
type Mechanic    = Types.Mechanic

local ActionValidator = {}

-- Validate an AgentAction against the legal actions for a mechanic.
-- Returns (true, nil) or (false, errorString).
function ActionValidator.validateAction(action: AgentAction, mechanic: Mechanic?): (boolean, string?)
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
	if type(state) ~= "table" then
		return false, "sector state must be a table"
	end
	if type(state.sector_id) ~= "number" then
		return false, "sector_id must be a number"
	end
	if type(state.params) ~= "table" then
		return false, "params must be a table"
	end
	if type(state.pads) ~= "table" then
		return false, "pads must be a table"
	end
	if state.pads.ingress ~= "None" and state.pads.ingress ~= "Boost" and state.pads.ingress ~= "Brake" then
		return false, "pads.ingress must be None, Boost, or Brake"
	end
	if state.pads.egress ~= "None" and state.pads.egress ~= "Boost" and state.pads.egress ~= "Brake" then
		return false, "pads.egress must be None, Boost, or Brake"
	end
	if type(state.version) ~= "number" then
		return false, "version must be a number"
	end

	if state.mechanic ~= nil then
		if type(state.mechanic) ~= "string" or LevelMappings.DEFAULTS[state.mechanic] == nil then
			return false, "mechanic must be a supported mechanic"
		end
		for _, lever in ipairs(LevelMappings.NUMERIC_LEVERS[state.mechanic]) do
			if type(state.params[lever]) ~= "number" then
				return false, "missing numeric lever: " .. lever
			end
		end
	elseif next(state.params) ~= nil then
		return false, "flat sector state must not include numeric params"
	end

	return true, nil
end

return ActionValidator
