local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local PadValueUtils = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("PadValueUtils"))
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
		extreme = { ramp_angle = 8, gap_length = 4, ramp_length = 4, landing_length = 2 },
		tall = { ramp_angle = 5, gap_length = 2 },
		steep = { ramp_angle = 5 },
		gentle = { ramp_angle = -5, gap_length = -2 },
		long = { ramp_length = 4, landing_length = 4 },
		short = { ramp_length = -4, landing_length = -4 },
	},
	Chicane = {
		-- amplitude bias reduced: default(5)+3=8 = TRACK_WIDTH/2 (max safe swing)
		extreme = { amplitude = 3, transition_length = -6, corridor_width = -3 },
		tight = { amplitude = 4, transition_length = -4, corridor_width = -2 },
		wide = { corridor_width = 4 },
		narrow = { corridor_width = -4 },
		long = { transition_length = 4 },
		short = { transition_length = -4 },
		gentle = { transition_length = 4, amplitude = -2 },
	},
	CrestDip = {
		extreme = { height_or_depth = 8, sector_length = -16 },
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
		params.amplitude = math.clamp(params.amplitude or 1, Constants.CHICANE_MIN_LATERAL_DISPLACEMENT, Constants.TRACK_WIDTH * 0.5)
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

local function strongerBoost(current: string): string
	return PadValueUtils.stronger("Boost", current)
end

local function strongerBrake(current: string): string
	return PadValueUtils.stronger("Brake", current)
end

local function weakerBoost(current: string): string
	return PadValueUtils.weaker("Boost", current)
end

local function weakerBrake(current: string): string
	return PadValueUtils.weaker("Brake", current)
end

local function crestSofteningDeltas(attemptIndex: number): (number, number)
	local severity = math.clamp(attemptIndex or 0, 0, 4)
	local lengthDelta = 8 + severity * 4
	local heightDelta = 2 + math.floor(severity / 2)
	return lengthDelta, heightDelta
end

function MinimalProposer.initial(request: Request): (SectorState?, string?)
	local committed = SectorRegistry.getCommitted(request.parsed.sector_id)
	if not committed then
		return nil, "sector " .. tostring(request.parsed.sector_id) .. " is not editable"
	end

	if request.parsed.request_kind == "Pad" then
		local nextState = cloneState(committed)
		nextState.pads[request.parsed.pad_side] = PadValueUtils.normalize(request.parsed.pad_value)
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

	if state.mechanic == "RampJump" and failure.type == "downstream_failure" then
		table.insert(candidates, { type = "SetNumericLever", lever = "ramp_angle", value = math.max(1, (params.ramp_angle or 0) - 5) })
		table.insert(candidates, { type = "SetNumericLever", lever = "gap_length", value = math.max(2, (params.gap_length or 0) - 2) })
		table.insert(candidates, { type = "SetNumericLever", lever = "landing_length", value = math.max(2, (params.landing_length or 0) + 2) })
		table.insert(candidates, { type = "SetPad", pad = "egress", value = strongerBrake(state.pads.egress) })
		table.insert(candidates, { type = "SetPad", pad = "ingress", value = weakerBoost(state.pads.ingress) })
		explanation = "post-jump instability detected; softened the landing"
	elseif failure.type == "downstream_failure" then
		table.insert(candidates, { type = "SetPad", pad = "egress", value = strongerBrake(state.pads.egress) })
		table.insert(candidates, { type = "SetPad", pad = "ingress", value = weakerBoost(state.pads.ingress) })
		explanation = "downstream instability detected; added egress brake"
	elseif state.mechanic == "RampJump" then
		if failure.type == "local_execution_failure" then
			table.insert(candidates, { type = "SetNumericLever", lever = "ramp_angle", value = math.max(1, (params.ramp_angle or 0) - 5) })
			table.insert(candidates, { type = "SetNumericLever", lever = "gap_length", value = math.max(2, (params.gap_length or 0) - 2) })
			table.insert(candidates, { type = "SetNumericLever", lever = "ramp_length", value = math.max(1, (params.ramp_length or 0) + 2) })
			table.insert(candidates, { type = "SetNumericLever", lever = "landing_length", value = math.max(2, (params.landing_length or 0) + 2) })
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBoost(state.pads.ingress) })
			table.insert(candidates, { type = "SetPad", pad = "egress", value = weakerBrake(state.pads.egress) })
			explanation = "jump traversal was unstable; softened the jump"
		elseif string.find(hintsText, "never became airborne", 1, true) then
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBoost(state.pads.ingress) })
			table.insert(candidates, { type = "SetNumericLever", lever = "ramp_angle", value = math.max(1, (params.ramp_angle or 0) + 5) })
			table.insert(candidates, { type = "SetNumericLever", lever = "ramp_length", value = math.max(1, (params.ramp_length or 0) + 2) })
			table.insert(candidates, { type = "SetNumericLever", lever = "gap_length", value = math.max(2, (params.gap_length or 0) - 2) })
			explanation = "jump never left the ground; steepened ramp and boosted entry"
		elseif string.find(hintsText, "air distance too short", 1, true) then
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBoost(state.pads.ingress) })
			table.insert(candidates, { type = "SetNumericLever", lever = "gap_length", value = math.max(2, (params.gap_length or 0) - 2) })
			table.insert(candidates, { type = "SetNumericLever", lever = "ramp_length", value = math.max(1, (params.ramp_length or 0) + 2) })
			table.insert(candidates, { type = "SetNumericLever", lever = "landing_length", value = math.max(2, (params.landing_length or 0) + 2) })
			explanation = "jump fell short; shortened the gap"
		elseif string.find(hintsText, "reacquire", 1, true)
			or string.find(hintsText, "reacquisition", 1, true) then
			table.insert(candidates, { type = "SetNumericLever", lever = "ramp_angle", value = math.max(1, (params.ramp_angle or 0) - 5) })
			table.insert(candidates, { type = "SetNumericLever", lever = "gap_length", value = math.max(2, (params.gap_length or 0) - 2) })
			table.insert(candidates, { type = "SetNumericLever", lever = "landing_length", value = math.max(2, (params.landing_length or 0) + 2) })
			table.insert(candidates, { type = "SetPad", pad = "egress", value = strongerBrake(state.pads.egress) })
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = weakerBoost(state.pads.ingress) })
			explanation = "landing was unstable; softened the exit"
		else
			table.insert(candidates, { type = "SetNumericLever", lever = "ramp_angle", value = math.max(1, (params.ramp_angle or 0) - 5) })
			table.insert(candidates, { type = "SetNumericLever", lever = "gap_length", value = math.max(2, (params.gap_length or 0) - 2) })
			table.insert(candidates, { type = "SetNumericLever", lever = "landing_length", value = math.max(2, (params.landing_length or 0) + 2) })
			table.insert(candidates, { type = "SetPad", pad = "egress", value = strongerBrake(state.pads.egress) })
			explanation = "jump was unstable; softened the landing"
		end
	elseif state.mechanic == "Chicane" then
		if string.find(hintsText, "lateral displacement", 1, true) then
			table.insert(candidates, { type = "SetNumericLever", lever = "amplitude", value = math.max(1, (params.amplitude or 0) + 2) })
			table.insert(candidates, {
				type = "SetNumericLever",
				lever = "corridor_width",
				value = math.clamp((params.corridor_width or 0) - 2, 1, Constants.TRACK_WIDTH),
			})
			explanation = "chicane is too shallow; increased amplitude"
		elseif string.find(hintsText, "curvature", 1, true) then
			table.insert(candidates, { type = "SetNumericLever", lever = "amplitude", value = math.max(1, (params.amplitude or 0) + 2) })
			table.insert(candidates, {
				type = "SetNumericLever",
				lever = "transition_length",
				value = math.clamp((params.transition_length or 0) - 2, 1, MAX_CHICANE_TRANSITION_LENGTH),
			})
			table.insert(candidates, {
				type = "SetNumericLever",
				lever = "corridor_width",
				value = math.clamp((params.corridor_width or 0) - 1, 1, Constants.TRACK_WIDTH),
			})
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBrake(state.pads.ingress) })
			table.insert(candidates, { type = "SetPad", pad = "egress", value = strongerBrake(state.pads.egress) })
			explanation = "chicane needs more turn severity; sharpened the S"
		elseif string.find(hintsText, "alternation", 1, true) then
			table.insert(candidates, { type = "SetNumericLever", lever = "amplitude", value = math.max(1, (params.amplitude or 0) + 1) })
			table.insert(candidates, {
				type = "SetNumericLever",
				lever = "transition_length",
				value = math.clamp((params.transition_length or 0) - 2, 1, MAX_CHICANE_TRANSITION_LENGTH),
			})
			table.insert(candidates, {
				type = "SetNumericLever",
				lever = "corridor_width",
				value = math.clamp((params.corridor_width or 0) - 1, 1, Constants.TRACK_WIDTH),
			})
			explanation = "chicane did not switch sides strongly enough; tightened the S"
		else
			-- Pads first: slowing the car before the chicane is less destructive
			-- than immediately softening the geometry of an extreme proposal.
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBrake(state.pads.ingress) })
			table.insert(candidates, { type = "SetPad", pad = "egress", value = strongerBrake(state.pads.egress) })
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
			table.insert(candidates, { type = "SetNumericLever", lever = "amplitude", value = math.max(1, (params.amplitude or 0) - 2) })
			explanation = "entry was unstable; adding brake pad before relaxing shape"
		end
	elseif state.mechanic == "CrestDip" then
		local sectorLengthCap = Constants.STRAIGHT_LENGTH - 10
		local softenLengthDelta, softenHeightDelta = crestSofteningDeltas(packet.attempt_index or 0)
		if string.find(hintsText, "airborne too long", 1, true) then
			table.insert(candidates, { type = "SetNumericLever", lever = "height_or_depth", value = math.max(2, (params.height_or_depth or 0) - 2) })
			table.insert(candidates, { type = "SetNumericLever", lever = "sector_length", value = math.min(sectorLengthCap, (params.sector_length or 0) + 10) })
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBrake(state.pads.ingress) })
			explanation = "car flew too far; softened the crest"
		elseif string.find(hintsText, "curvature", 1, true) then
			table.insert(candidates, { type = "SetNumericLever", lever = "height_or_depth", value = math.max(2, (params.height_or_depth or 0) + 2) })
			table.insert(candidates, { type = "SetNumericLever", lever = "sector_length", value = math.max(12, (params.sector_length or 0) - 10) })
			explanation = "crest too gentle; sharpened the curve"
		elseif string.find(hintsText, "vertical displacement", 1, true) then
			table.insert(candidates, { type = "SetNumericLever", lever = "height_or_depth", value = math.max(2, (params.height_or_depth or 0) + 2) })
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBoost(state.pads.ingress) })
			explanation = "crest or dip is too subtle; raised the peak"
		elseif string.find(hintsText, "reacquire", 1, true)
			or string.find(hintsText, "reacquisition", 1, true) then
			table.insert(candidates, { type = "SetPad", pad = "egress", value = strongerBrake(state.pads.egress) })
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = weakerBoost(state.pads.ingress) })
			table.insert(candidates, { type = "SetNumericLever", lever = "sector_length", value = math.min(sectorLengthCap, (params.sector_length or 0) + 8) })
			table.insert(candidates, { type = "SetNumericLever", lever = "height_or_depth", value = math.max(2, (params.height_or_depth or 0) - 2) })
			explanation = "reacquisition unstable; softened the landing"
		elseif failure.type == "local_execution_failure" then
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBoost(state.pads.ingress) })
			table.insert(candidates, {
				type = "SetNumericLever",
				lever = "sector_length",
				value = math.min(sectorLengthCap, (params.sector_length or 0) + softenLengthDelta),
			})
			table.insert(candidates, {
				type = "SetNumericLever",
				lever = "height_or_depth",
				value = math.max(2, (params.height_or_depth or 0) - softenHeightDelta),
			})
			table.insert(candidates, { type = "SetPad", pad = "egress", value = weakerBrake(state.pads.egress) })
			explanation = "the crest stalled the car; boosted entry and softened the feature"
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
