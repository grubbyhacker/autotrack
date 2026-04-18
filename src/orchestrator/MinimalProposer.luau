local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local ChicanePath = require(script.Parent.Parent.Mechanics.ChicanePath)

type Request = Types.Request
type SectorState = Types.SectorState
type FailurePacket = Types.FailurePacket
type AgentAction = Types.AgentAction

local MinimalProposer = {}
local MAX_CHICANE_TRANSITION_LENGTH = math.floor(
	(Constants.STRAIGHT_LENGTH - ChicanePath.ENTRY_STRAIGHT - ChicanePath.EXIT_STRAIGHT) / 3
)

local QUALIFIER_BIASES = {
	RampJump = {
		tall = { ramp_angle = 5, gap_length = 2 },
		steep = { ramp_angle = 5 },
		gentle = { ramp_angle = -5, gap_length = -2 },
		long = { ramp_length = 4, landing_length = 4 },
		short = { ramp_length = -4, landing_length = -4 },
	},
	Chicane = {
		tight = { amplitude = 4, transition_length = -4, corridor_width = -2 },
		wide = { corridor_width = 4 },
		narrow = { corridor_width = -4 },
		long = { transition_length = 4 },
		short = { transition_length = -4 },
		gentle = { transition_length = 4, amplitude = -2 },
	},
	CrestDip = {
		really = { height_or_depth = 6, sector_length = -12 },
		tall = { height_or_depth = 4, sector_length = -4 },
		steep = { height_or_depth = 4, sector_length = -8 },
		gentle = { height_or_depth = -2, sector_length = 8 },
		long = { sector_length = 20 },
		short = { sector_length = -10 },
		shallow = { height_or_depth = -3 },
		deep = { height_or_depth = 4, sector_length = -4 },
	},
}

local function cloneParams(params)
	local out = {}
	for key, value in pairs(params) do
		out[key] = value
	end
	return out
end

local function cloneState(state)
	return {
		sector_id = state.sector_id,
		mechanic = state.mechanic,
		params = cloneParams(state.params),
		pads = {
			ingress = state.pads.ingress,
			egress = state.pads.egress,
		},
		version = state.version,
	}
end

local function applyParamDelta(params, deltas)
	for key, delta in pairs(deltas) do
		local current = params[key]
		if type(current) == "number" then
			params[key] = math.max(1, current + delta)
		end
	end
end

local function normalizeParams(mechanic, params)
	if mechanic == "Chicane" then
		params.transition_length = math.clamp(params.transition_length or 1, 1, MAX_CHICANE_TRANSITION_LENGTH)
		params.corridor_width = math.clamp(params.corridor_width or 1, 1, Constants.TRACK_WIDTH)
	end
	return params
end

local function actionEquals(a: AgentAction?, b: AgentAction?): boolean
	if a == nil or b == nil then
		return a == b
	end
	if a.type ~= b.type then
		return false
	end
	if a.type == "SetNumericLever" and b.type == "SetNumericLever" then
		return a.lever == b.lever and a.value == b.value
	end
	if a.type == "SetPad" and b.type == "SetPad" then
		return a.pad == b.pad and a.value == b.value
	end
	return false
end

local function actionChangesState(state: SectorState, action: AgentAction): boolean
	if action.type == "SetPad" then
		return state.pads[action.pad] ~= action.value
	end

	local current = state.params[action.lever]
	return type(current) ~= "number" or current ~= action.value
end

local function choose(packet: FailurePacket, candidates: { AgentAction }): (AgentAction?, string?)
	for _, candidate in ipairs(candidates) do
		if actionChangesState(packet.sector_state, candidate) and not actionEquals(candidate, packet.last_action) then
			return candidate
		end
	end
	return nil, "no legal state-changing repair action available"
end

function MinimalProposer.initial(request: Request): (SectorState?, string?)
	local committed = SectorRegistry.getCommitted(request.parsed.sector_id)
	if not committed then
		return nil, "sector " .. tostring(request.parsed.sector_id) .. " is not editable"
	end

	if request.parsed.request_kind == "Pad" then
		local nextState = cloneState(committed)
		nextState.pads[request.parsed.pad_side] = request.parsed.pad_value
		return nextState, nil
	end

	local mechanic = request.parsed.mechanic
	local defaults = LevelMappings.DEFAULTS[mechanic]
	if not defaults then
		return nil, "unsupported mechanic: " .. tostring(mechanic)
	end

	local params = cloneParams(defaults)
	local mechanicBiases = QUALIFIER_BIASES[mechanic] or {}
	local hasReally = false
	for _, qualifier in ipairs(request.qualifiers) do
		if qualifier == "really" then
			hasReally = true
			break
		end
	end
	for _, qualifier in ipairs(request.qualifiers) do
		local bias = mechanicBiases[qualifier]
		if bias then
			applyParamDelta(params, bias)
			if hasReally and qualifier ~= "really" and mechanic ~= "CrestDip" then
				applyParamDelta(params, bias)
			end
		end
	end
	params = normalizeParams(mechanic, params)

	return {
		sector_id = request.parsed.sector_id,
		mechanic = mechanic,
		params = params,
		pads = {
			ingress = "None",
			egress = "None",
		},
		version = committed.version,
	}, nil
end

function MinimalProposer.repair(packet: FailurePacket): (AgentAction?, string?, string?)
	local failure = packet.run_result.failure
	if not failure then
		return nil, nil, "cannot repair a successful run"
	end

	local hintsText = string.lower(table.concat(packet.diagnostics.hints, " | "))
	local state = packet.sector_state
	local params = state.params
	local candidates = {}
	local explanation = "adjusted the target sector"

	if failure.type == "downstream_failure" then
		table.insert(candidates, { type = "SetPad", pad = "egress", value = "Brake" })
		explanation = "downstream instability detected; added egress brake"
	elseif state.mechanic == "RampJump" then
		if string.find(hintsText, "never became airborne", 1, true) then
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = "Boost" })
			table.insert(candidates, { type = "SetNumericLever", lever = "ramp_angle", value = math.max(1, (params.ramp_angle or 0) + 5) })
			table.insert(candidates, { type = "SetNumericLever", lever = "ramp_length", value = math.max(1, (params.ramp_length or 0) + 2) })
			explanation = "jump undershot; boosted the entry"
		elseif string.find(hintsText, "air distance too short", 1, true) then
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = "Boost" })
			table.insert(candidates, { type = "SetNumericLever", lever = "gap_length", value = math.max(2, (params.gap_length or 0) + 2) })
			table.insert(candidates, { type = "SetNumericLever", lever = "ramp_angle", value = math.max(1, (params.ramp_angle or 0) + 5) })
			table.insert(candidates, { type = "SetNumericLever", lever = "ramp_length", value = math.max(1, (params.ramp_length or 0) + 2) })
			explanation = "jump lacked airtime; boosted the entry"
		elseif string.find(hintsText, "reacquire", 1, true)
			or string.find(hintsText, "reacquisition", 1, true) then
			table.insert(candidates, { type = "SetPad", pad = "egress", value = "Brake" })
			table.insert(candidates, { type = "SetNumericLever", lever = "ramp_angle", value = math.max(1, (params.ramp_angle or 0) - 5) })
			table.insert(candidates, { type = "SetNumericLever", lever = "landing_length", value = math.max(2, (params.landing_length or 0) + 2) })
			explanation = "landing was unstable; softened the exit"
		else
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = "Boost" })
			table.insert(candidates, { type = "SetNumericLever", lever = "ramp_angle", value = math.max(1, (params.ramp_angle or 0) + 5) })
		end
	elseif state.mechanic == "Chicane" then
		if string.find(hintsText, "lateral displacement", 1, true) then
			table.insert(candidates, { type = "SetNumericLever", lever = "amplitude", value = math.max(1, (params.amplitude or 0) + 2) })
			explanation = "chicane is too shallow; increased amplitude"
		elseif string.find(hintsText, "curvature", 1, true) then
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = "Brake" })
			table.insert(candidates, { type = "SetNumericLever", lever = "amplitude", value = math.max(1, (params.amplitude or 0) + 2) })
			table.insert(candidates, {
				type = "SetNumericLever",
				lever = "transition_length",
				value = math.clamp((params.transition_length or 0) - 2, 1, MAX_CHICANE_TRANSITION_LENGTH),
			})
			table.insert(candidates, { type = "SetPad", pad = "egress", value = "Brake" })
			explanation = "chicane needs more turn severity; slowed the entry"
		else
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = "Brake" })
			table.insert(candidates, {
				type = "SetNumericLever",
				lever = "transition_length",
				value = math.clamp((params.transition_length or 0) + 6, 1, MAX_CHICANE_TRANSITION_LENGTH),
			})
			table.insert(candidates, {
				type = "SetNumericLever",
				lever = "corridor_width",
				value = math.clamp((params.corridor_width or 0) + 4, 1, Constants.TRACK_WIDTH),
			})
			table.insert(candidates, { type = "SetPad", pad = "egress", value = "Brake" })
			explanation = "entry was unstable; relaxed the turn radius"
		end
	elseif state.mechanic == "CrestDip" then
		local sectorLengthCap = Constants.STRAIGHT_LENGTH - 10
		if string.find(hintsText, "airborne too long", 1, true) then
			table.insert(candidates, { type = "SetNumericLever", lever = "height_or_depth", value = math.max(2, (params.height_or_depth or 0) - 2) })
			table.insert(candidates, { type = "SetNumericLever", lever = "sector_length", value = math.min(sectorLengthCap, (params.sector_length or 0) + 10) })
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = "Brake" })
			explanation = "car flew too far; softened the crest"
		elseif string.find(hintsText, "curvature", 1, true) then
			table.insert(candidates, { type = "SetNumericLever", lever = "height_or_depth", value = math.max(2, (params.height_or_depth or 0) + 2) })
			table.insert(candidates, { type = "SetNumericLever", lever = "sector_length", value = math.max(12, (params.sector_length or 0) - 10) })
			explanation = "crest too gentle; sharpened the curve"
		elseif string.find(hintsText, "vertical displacement", 1, true) then
			table.insert(candidates, { type = "SetNumericLever", lever = "height_or_depth", value = math.max(2, (params.height_or_depth or 0) + 2) })
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = "Boost" })
			explanation = "crest or dip is too subtle; raised the peak"
		elseif string.find(hintsText, "reacquire", 1, true)
			or string.find(hintsText, "reacquisition", 1, true) then
			table.insert(candidates, { type = "SetPad", pad = "egress", value = "Brake" })
			table.insert(candidates, { type = "SetNumericLever", lever = "sector_length", value = math.min(sectorLengthCap, (params.sector_length or 0) + 8) })
			table.insert(candidates, { type = "SetNumericLever", lever = "height_or_depth", value = math.max(2, (params.height_or_depth or 0) - 2) })
			explanation = "reacquisition unstable; softened the landing"
		elseif failure.type == "local_execution_failure" then
			table.insert(candidates, { type = "SetNumericLever", lever = "sector_length", value = math.min(sectorLengthCap, (params.sector_length or 0) + 6) })
			table.insert(candidates, { type = "SetNumericLever", lever = "height_or_depth", value = math.max(2, (params.height_or_depth or 0) - 2) })
			table.insert(candidates, { type = "SetPad", pad = "egress", value = "Brake" })
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = "Boost" })
			explanation = "the crest was too abrupt; lengthened the feature"
		else
			table.insert(candidates, { type = "SetNumericLever", lever = "height_or_depth", value = math.max(2, (params.height_or_depth or 0) + 2) })
			table.insert(candidates, { type = "SetNumericLever", lever = "sector_length", value = math.min(sectorLengthCap, (params.sector_length or 0) + 4) })
		end
	else
		return nil, nil, "unsupported mechanic in repair: " .. tostring(state.mechanic)
	end

	local action, chooseErr = choose(packet, candidates)
	if not action then
		return nil, nil, chooseErr
	end

	return action, explanation, nil
end

return MinimalProposer
