local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local PadValueUtils = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("PadValueUtils"))
local CrestDipTuner = require(script.Parent.Parent.Mechanics.CrestDipTuner)
local RampJumpTuner = require(script.Parent.Parent.Mechanics.RampJumpTuner)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local ChicanePath = require(script.Parent.Parent.Mechanics.ChicanePath)

type Request = Types.Request
type SectorState = Types.SectorState
type FailurePacket = Types.FailurePacket
type AgentAction = Types.AgentAction

local MinimalProposer = {}
local MAX_CHICANE_TRANSITION_LENGTH = ChicanePath.maxTransitionLength()

local QUALIFIER_BIASES = {
	RampJump = {
		extreme = { ramp_angle = 4, gap_length = 2, ramp_length = 2, landing_length = 4 },
		tall = { ramp_angle = 2, gap_length = 1 },
		steep = { ramp_angle = 2 },
		gentle = { ramp_angle = -2, gap_length = -1, landing_length = 2 },
		long = { ramp_length = 2, landing_length = 4 },
		short = { ramp_length = -2, gap_length = -1 },
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
		extreme = { height_or_depth = 7, sector_length = -10 },
		really = { height_or_depth = 5, sector_length = -8 },
		tall = { height_or_depth = 3, sector_length = -2 },
		steep = { height_or_depth = 2, sector_length = -4 },
		gentle = { height_or_depth = -2, sector_length = 6 },
		long = { sector_length = 10 },
		short = { sector_length = -6 },
		shallow = { height_or_depth = -3, sector_length = 4 },
		deep = { height_or_depth = 3, sector_length = -2 },
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
	if mechanic == "RampJump" then
		return RampJumpTuner.tune(params)
	elseif mechanic == "Chicane" then
		params.amplitude = math.clamp(
			params.amplitude or 1,
			Constants.CHICANE_MIN_LATERAL_DISPLACEMENT,
			math.min(LevelMappings.LEVER_BOUNDS.Chicane.amplitude.max, Constants.TRACK_WIDTH * 0.5)
		)
		params.transition_length = math.clamp(
			params.transition_length or LevelMappings.DEFAULTS.Chicane.transition_length,
			LevelMappings.LEVER_BOUNDS.Chicane.transition_length.min,
			math.min(LevelMappings.LEVER_BOUNDS.Chicane.transition_length.max, MAX_CHICANE_TRANSITION_LENGTH)
		)
		params.corridor_width = math.clamp(
			params.corridor_width or LevelMappings.DEFAULTS.Chicane.corridor_width,
			LevelMappings.LEVER_BOUNDS.Chicane.corridor_width.min,
			math.min(LevelMappings.LEVER_BOUNDS.Chicane.corridor_width.max, Constants.TRACK_WIDTH)
		)
	elseif mechanic == "CrestDip" then
		params.height_or_depth = math.clamp(
			params.height_or_depth or LevelMappings.DEFAULTS.CrestDip.height_or_depth,
			LevelMappings.LEVER_BOUNDS.CrestDip.height_or_depth.min,
			LevelMappings.LEVER_BOUNDS.CrestDip.height_or_depth.max
		)
		params.sector_length = math.clamp(
			params.sector_length or LevelMappings.DEFAULTS.CrestDip.sector_length,
			LevelMappings.LEVER_BOUNDS.CrestDip.sector_length.min,
			LevelMappings.LEVER_BOUNDS.CrestDip.sector_length.max
		)
		params.radius = math.clamp(params.radius or LevelMappings.DEFAULTS.CrestDip.radius, 8, 40)
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

local function crestIngressBoost(current: string, entrySpeed: number?): string
	local speed = entrySpeed or 0
	if speed > 0 and speed <= Constants.CAR_TARGET_SPEED * 0.4 then
		local normalized = PadValueUtils.normalize(current)
		if PadValueUtils.kind(normalized) ~= "Boost" or PadValueUtils.amount(normalized) < 25 then
			return "Boost25"
		end
	end
	return strongerBoost(current)
end

local function crestSofteningDeltas(attemptIndex: number): (number, number)
	local severity = math.clamp(attemptIndex or 0, 0, 4)
	local lengthDelta = 4 + severity * 2
	local heightDelta = 1 + math.floor(severity / 2)
	return lengthDelta, heightDelta
end

local function crestBounds()
	return LevelMappings.LEVER_BOUNDS.CrestDip.height_or_depth, LevelMappings.LEVER_BOUNDS.CrestDip.sector_length
end

local function crestTuneTarget(height: number, sectorLength: number, bounds): (number, number)
	local heightBounds, lengthBounds = crestBounds()
	return CrestDipTuner.tune(
		math.clamp(math.round(height), heightBounds.min, heightBounds.max),
		math.clamp(math.round(sectorLength), lengthBounds.min, lengthBounds.max),
		bounds
	)
end

local function appendCrestTuneCandidates(
	candidates: { AgentAction },
	params,
	desiredHeight: number,
	desiredLength: number,
	preferHeightFirst: boolean,
	bounds
)
	local tunedHeight, tunedLength = crestTuneTarget(desiredHeight, desiredLength, bounds)
	local currentHeight = params.height_or_depth or 0
	local currentLength = params.sector_length or 0

	local function appendHeight()
		if tunedHeight ~= currentHeight then
			table.insert(candidates, {
				type = "SetNumericLever",
				lever = "height_or_depth",
				value = tunedHeight,
			})
		end
	end

	local function appendLength()
		if tunedLength ~= currentLength then
			table.insert(candidates, {
				type = "SetNumericLever",
				lever = "sector_length",
				value = tunedLength,
			})
		end
	end

	if preferHeightFirst then
		appendHeight()
		appendLength()
	else
		appendLength()
		appendHeight()
	end
end

local function targetProgress(packet: FailurePacket): number
	return packet.run_result.metrics.target_progress or 0
end

local function rampAngleFloor(): number
	return LevelMappings.LEVER_BOUNDS.RampJump.ramp_angle.min
end

local function rampLengthFloor(): number
	return LevelMappings.LEVER_BOUNDS.RampJump.ramp_length.min
end

local function gapLengthFloor(): number
	return math.max(2, Constants.RAMPJUMP_MIN_GAP)
end

local function landingLengthFloor(): number
	return LevelMappings.LEVER_BOUNDS.RampJump.landing_length.min
end

local function chicaneAmplitudeFloor(): number
	return Constants.CHICANE_MIN_LATERAL_DISPLACEMENT
end

local function crestHeightFloor(): number
	return Constants.CRESTDIP_MIN_VERTICAL_DISPLACEMENT
end

local function isPostCornerEditableSector(sectorId: number): boolean
	return sectorId == 2 or sectorId == 7
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

	local plainCrestRequest = mechanic == "CrestDip" and #request.qualifiers == 0
	local postCornerCrest = mechanic == "CrestDip" and isPostCornerEditableSector(request.parsed.sector_id)
	if mechanic == "CrestDip" and (plainCrestRequest or postCornerCrest) then
		params.sector_length = math.min(params.sector_length, 30)
	end
	if mechanic == "RampJump" then
		params = RampJumpTuner.tune(params, {
			postCorner = isPostCornerEditableSector(request.parsed.sector_id),
			preferGentle = #request.qualifiers == 0,
		})
	end

	local ingressPad = if mechanic == "CrestDip" then "Brake25" elseif mechanic == "RampJump" then "Brake25" else "None"
	if mechanic == "CrestDip" and plainCrestRequest then
		ingressPad = "Brake50"
	end
	if postCornerCrest then
		ingressPad = "Brake25"
	end
	if mechanic == "RampJump" and isPostCornerEditableSector(request.parsed.sector_id) then
		ingressPad = "Brake50"
	end
	local egressPad = if mechanic == "RampJump"
		then (if isPostCornerEditableSector(request.parsed.sector_id) then "Brake25" else "Brake10")
		else "None"

	return {
		sector_id = request.parsed.sector_id,
		mechanic = mechanic,
		params = params,
		pads = {
			ingress = ingressPad,
			egress = egressPad,
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
	local metrics = packet.run_result.metrics
	local candidates = {}
	local explanation = "adjusted the target sector"

	if state.mechanic == "RampJump" and failure.type == "downstream_failure" then
		table.insert(candidates, { type = "SetPad", pad = "egress", value = strongerBrake(state.pads.egress) })
		table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBrake(state.pads.ingress) })
		table.insert(candidates, { type = "SetNumericLever", lever = "landing_length", value = math.min(LevelMappings.LEVER_BOUNDS.RampJump.landing_length.max, (params.landing_length or 0) + 6) })
		table.insert(candidates, { type = "SetNumericLever", lever = "ramp_angle", value = math.max(rampAngleFloor(), (params.ramp_angle or 0) - 2) })
		table.insert(candidates, { type = "SetNumericLever", lever = "gap_length", value = math.max(gapLengthFloor(), (params.gap_length or 0) - 1) })
		explanation = "post-jump instability detected; braking the exit and widening the recovery"
	elseif state.mechanic == "CrestDip" and failure.type == "downstream_failure" then
		local downstreamNeedsSpeed = string.find(hintsText, "exit speed too low", 1, true) ~= nil
			or string.find(hintsText, "no_progress", 1, true) ~= nil
			or string.find(hintsText, "stall", 1, true) ~= nil
		local unstableExit = metrics.target_reacquired == false
			or string.find(hintsText, "exit attitude unstable", 1, true) ~= nil
			or string.find(hintsText, "reacquire", 1, true) ~= nil
		local sectorLengthCap = if isPostCornerEditableSector(state.sector_id)
			then 34
			else Constants.STRAIGHT_LENGTH - 10
		local softenLengthDelta, softenHeightDelta = crestSofteningDeltas(packet.attempt_index or 0)

		if downstreamNeedsSpeed then
			local ingressCarrySpeed = crestIngressBoost(state.pads.ingress, metrics.entry_speed)
			if PadValueUtils.kind(state.pads.ingress) == "Brake" then
				ingressCarrySpeed = weakerBrake(state.pads.ingress)
			end
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = ingressCarrySpeed })
			table.insert(candidates, { type = "SetPad", pad = "egress", value = weakerBrake(state.pads.egress) })
			table.insert(candidates, {
				type = "SetNumericLever",
				lever = "height_or_depth",
				value = math.max(crestHeightFloor(), (params.height_or_depth or 0) - softenHeightDelta),
			})
			table.insert(candidates, {
				type = "SetNumericLever",
				lever = "sector_length",
				value = math.min(sectorLengthCap, (params.sector_length or 0) + softenLengthDelta),
			})
			explanation = "downstream sector lost too much speed after the crest; carrying more speed out"
		elseif unstableExit then
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBrake(state.pads.ingress) })
			table.insert(candidates, { type = "SetPad", pad = "egress", value = weakerBrake(state.pads.egress) })
			table.insert(candidates, {
				type = "SetNumericLever",
				lever = "height_or_depth",
				value = math.max(crestHeightFloor(), (params.height_or_depth or 0) - softenHeightDelta),
			})
			table.insert(candidates, {
				type = "SetNumericLever",
				lever = "sector_length",
				value = math.min(sectorLengthCap, (params.sector_length or 0) + softenLengthDelta),
			})
			explanation = "crest exited unstable into the next sector; slowing entry and calming the rejoin"
		else
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBrake(state.pads.ingress) })
			table.insert(candidates, { type = "SetPad", pad = "egress", value = weakerBrake(state.pads.egress) })
			table.insert(candidates, {
				type = "SetNumericLever",
				lever = "height_or_depth",
				value = math.max(crestHeightFloor(), (params.height_or_depth or 0) - softenHeightDelta),
			})
			table.insert(candidates, {
				type = "SetNumericLever",
				lever = "sector_length",
				value = math.min(sectorLengthCap, (params.sector_length or 0) + softenLengthDelta),
			})
			explanation = "downstream sector destabilized after the crest; slowed entry and softened the feature"
		end
	elseif failure.type == "downstream_failure" then
		table.insert(candidates, { type = "SetPad", pad = "egress", value = strongerBrake(state.pads.egress) })
		table.insert(candidates, { type = "SetPad", pad = "ingress", value = weakerBoost(state.pads.ingress) })
		explanation = "downstream instability detected; added egress brake"
	elseif state.mechanic == "RampJump" then
		local progress = targetProgress(packet)
		local failureDetail = string.lower(tostring(failure.detail or ""))
		local stalledOnTakeoff = string.find(hintsText, "no_progress", 1, true) ~= nil
			or string.find(hintsText, "stall", 1, true) ~= nil
			or failureDetail == "no_progress"
			or failureDetail == "stall"
		local unstableOnTakeoff = failureDetail == "invalid_attitude"
			or failureDetail == "overturn"
			or failureDetail == "backward_facing"
			or failureDetail == "tumble"
			or failureDetail == "spinout"
			or failureDetail == "off_track"
			or failureDetail == "fell_below_kill_plane"
		if failure.type == "local_execution_failure" then
			if stalledOnTakeoff then
				table.insert(candidates, { type = "SetNumericLever", lever = "ramp_angle", value = math.max(rampAngleFloor(), (params.ramp_angle or 0) - 2) })
				table.insert(candidates, { type = "SetNumericLever", lever = "ramp_length", value = math.min(LevelMappings.LEVER_BOUNDS.RampJump.ramp_length.max, (params.ramp_length or 0) + 2) })
				table.insert(candidates, { type = "SetNumericLever", lever = "gap_length", value = math.max(gapLengthFloor(), (params.gap_length or 0) - 1) })
				table.insert(candidates, { type = "SetNumericLever", lever = "landing_length", value = math.min(LevelMappings.LEVER_BOUNDS.RampJump.landing_length.max, (params.landing_length or 0) + 4) })
				table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBrake(state.pads.ingress) })
				explanation = "ramp bogged down on the climb; softened the approach and extended the runout"
			elseif unstableOnTakeoff and progress < 0.30 then
				table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBrake(state.pads.ingress) })
				table.insert(candidates, { type = "SetPad", pad = "egress", value = strongerBrake(state.pads.egress) })
				table.insert(candidates, { type = "SetNumericLever", lever = "ramp_angle", value = math.max(rampAngleFloor(), (params.ramp_angle or 0) - 3) })
				table.insert(candidates, { type = "SetNumericLever", lever = "ramp_length", value = math.min(LevelMappings.LEVER_BOUNDS.RampJump.ramp_length.max, (params.ramp_length or 0) + 2) })
				table.insert(candidates, { type = "SetNumericLever", lever = "gap_length", value = math.max(gapLengthFloor(), (params.gap_length or 0) - 1) })
				table.insert(candidates, { type = "SetNumericLever", lever = "landing_length", value = math.min(LevelMappings.LEVER_BOUNDS.RampJump.landing_length.max, (params.landing_length or 0) + 6) })
				explanation = "ramp entry was acting like a wall; flattened the approach and widened the landing"
			elseif progress >= 0.30 then
				table.insert(candidates, { type = "SetPad", pad = "egress", value = strongerBrake(state.pads.egress) })
				table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBrake(state.pads.ingress) })
				table.insert(candidates, { type = "SetNumericLever", lever = "landing_length", value = math.min(LevelMappings.LEVER_BOUNDS.RampJump.landing_length.max, (params.landing_length or 0) + 6) })
				table.insert(candidates, { type = "SetNumericLever", lever = "ramp_angle", value = math.max(rampAngleFloor(), (params.ramp_angle or 0) - 2) })
				explanation = "landing was too lively; lengthened the runout and reduced the launch severity"
			else
				table.insert(candidates, { type = "SetNumericLever", lever = "ramp_angle", value = math.max(rampAngleFloor(), (params.ramp_angle or 0) - 2) })
				table.insert(candidates, { type = "SetNumericLever", lever = "ramp_length", value = math.min(LevelMappings.LEVER_BOUNDS.RampJump.ramp_length.max, (params.ramp_length or 0) + 2) })
				table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBrake(state.pads.ingress) })
				explanation = "ramp approach was unstable; softened the climb"
			end
		elseif string.find(hintsText, "vertical displacement too small", 1, true) then
			table.insert(candidates, { type = "SetNumericLever", lever = "ramp_angle", value = math.min(LevelMappings.LEVER_BOUNDS.RampJump.ramp_angle.max, (params.ramp_angle or 0) + 2) })
			table.insert(candidates, { type = "SetNumericLever", lever = "ramp_length", value = math.min(LevelMappings.LEVER_BOUNDS.RampJump.ramp_length.max, (params.ramp_length or 0) + 2) })
			table.insert(candidates, { type = "SetNumericLever", lever = "gap_length", value = math.min(LevelMappings.LEVER_BOUNDS.RampJump.gap_length.max, (params.gap_length or 0) + 1) })
			explanation = "ramp was too flat to read; added a small amount of lift without turning it into a stunt jump"
		elseif string.find(hintsText, "reacquire", 1, true)
			or string.find(hintsText, "reacquisition", 1, true) then
			table.insert(candidates, { type = "SetPad", pad = "egress", value = strongerBrake(state.pads.egress) })
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBrake(state.pads.ingress) })
			table.insert(candidates, { type = "SetNumericLever", lever = "landing_length", value = math.min(LevelMappings.LEVER_BOUNDS.RampJump.landing_length.max, (params.landing_length or 0) + 6) })
			table.insert(candidates, { type = "SetNumericLever", lever = "ramp_angle", value = math.max(rampAngleFloor(), (params.ramp_angle or 0) - 2) })
			table.insert(candidates, { type = "SetNumericLever", lever = "gap_length", value = math.max(gapLengthFloor(), (params.gap_length or 0) - 1) })
			explanation = "landing was unstable; trimmed speed and lengthened the landing"
		else
			if progress >= 0.30 then
				table.insert(candidates, { type = "SetPad", pad = "egress", value = strongerBrake(state.pads.egress) })
				table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBrake(state.pads.ingress) })
				table.insert(candidates, { type = "SetNumericLever", lever = "landing_length", value = math.min(LevelMappings.LEVER_BOUNDS.RampJump.landing_length.max, (params.landing_length or 0) + 4) })
				table.insert(candidates, { type = "SetNumericLever", lever = "ramp_angle", value = math.max(rampAngleFloor(), (params.ramp_angle or 0) - 1) })
				explanation = "ramp landing stayed rough; softened the exit"
			else
				table.insert(candidates, { type = "SetNumericLever", lever = "ramp_angle", value = math.max(rampAngleFloor(), (params.ramp_angle or 0) - 2) })
				table.insert(candidates, { type = "SetNumericLever", lever = "ramp_length", value = math.min(LevelMappings.LEVER_BOUNDS.RampJump.ramp_length.max, (params.ramp_length or 0) + 2) })
				table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBrake(state.pads.ingress) })
				explanation = "ramp was unstable before the crest; flattened the approach"
			end
		end
	elseif state.mechanic == "Chicane" then
		if string.find(hintsText, "lateral displacement", 1, true) then
			table.insert(candidates, { type = "SetNumericLever", lever = "amplitude", value = math.max(chicaneAmplitudeFloor(), (params.amplitude or 0) + 2) })
			table.insert(candidates, {
				type = "SetNumericLever",
				lever = "corridor_width",
				value = math.clamp((params.corridor_width or 0) - 2, 1, Constants.TRACK_WIDTH),
			})
			explanation = "chicane is too shallow; increased amplitude"
		elseif string.find(hintsText, "curvature", 1, true) then
			table.insert(candidates, { type = "SetNumericLever", lever = "amplitude", value = math.max(chicaneAmplitudeFloor(), (params.amplitude or 0) + 2) })
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
			table.insert(candidates, { type = "SetNumericLever", lever = "amplitude", value = math.max(chicaneAmplitudeFloor(), (params.amplitude or 0) + 1) })
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
			local progress = (packet.run_result.metrics.target_progress or 0)
			local stalledInChicane = string.find(hintsText, "no_progress", 1, true) ~= nil
				or string.find(hintsText, "stall", 1, true) ~= nil
			if progress < 0.30 then
				-- Early entry failure: open the line before we sacrifice speed.
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
				table.insert(candidates, { type = "SetNumericLever", lever = "amplitude", value = math.max(chicaneAmplitudeFloor(), (params.amplitude or 0) - 2) })
				table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBrake(state.pads.ingress) })
				table.insert(candidates, { type = "SetPad", pad = "egress", value = strongerBrake(state.pads.egress) })
				explanation = "chicane too sharp for entry; relaxed geometry first"
			elseif stalledInChicane then
				table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBrake(state.pads.ingress) })
				table.insert(candidates, {
					type = "SetNumericLever",
					lever = "corridor_width",
					value = math.clamp((params.corridor_width or 0) + 4, 1, Constants.TRACK_WIDTH),
				})
				table.insert(candidates, {
					type = "SetNumericLever",
					lever = "transition_length",
					value = math.clamp((params.transition_length or 0) + 6, 1, MAX_CHICANE_TRANSITION_LENGTH),
				})
				table.insert(candidates, { type = "SetNumericLever", lever = "amplitude", value = math.max(chicaneAmplitudeFloor(), (params.amplitude or 0) - 2) })
				table.insert(candidates, { type = "SetPad", pad = "egress", value = strongerBrake(state.pads.egress) })
				explanation = "chicane overloaded the car; slowed entry and opened the line"
			else
				-- Car made real progress into the chicane but failed mid-traverse:
				-- entry speed is the issue. Brake pads come before geometry.
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
				table.insert(candidates, { type = "SetNumericLever", lever = "amplitude", value = math.max(chicaneAmplitudeFloor(), (params.amplitude or 0) - 2) })
				explanation = "entry was unstable; adding brake pad before relaxing shape"
			end
		end
	elseif state.mechanic == "CrestDip" then
		local sectorLengthCap = if isPostCornerEditableSector(state.sector_id)
			then 34
			else Constants.STRAIGHT_LENGTH - 10
		local softenLengthDelta, softenHeightDelta = crestSofteningDeltas(packet.attempt_index or 0)
		local stalledOnCrest = string.find(hintsText, "no_progress", 1, true) ~= nil
			or string.find(hintsText, "stall", 1, true) ~= nil
		local failureDetail = string.lower(tostring(failure.detail or ""))
		stalledOnCrest = stalledOnCrest
			or failureDetail == "no_progress"
			or failureDetail == "stall"
		local unstableCrash = failureDetail == "tumble"
			or failureDetail == "spinout"
			or failureDetail == "overturn"
			or failureDetail == "invalid_attitude"
			or failureDetail == "backward_facing"
			or failureDetail == "off_track"
			or failureDetail == "fell_below_kill_plane"
		if string.find(hintsText, "airborne too long", 1, true) then
			appendCrestTuneCandidates(
				candidates,
				params,
				math.max(crestHeightFloor(), (params.height_or_depth or 0) - 2),
				math.min(sectorLengthCap, (params.sector_length or 0) + 10),
				true,
				{
					maxHeight = params.height_or_depth or LevelMappings.LEVER_BOUNDS.CrestDip.height_or_depth.max,
					minLength = params.sector_length or LevelMappings.LEVER_BOUNDS.CrestDip.sector_length.min,
				}
			)
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBrake(state.pads.ingress) })
			explanation = "car flew too far; softened the crest"
		elseif string.find(hintsText, "curvature", 1, true) then
			appendCrestTuneCandidates(
				candidates,
				params,
				(params.height_or_depth or 0) + 1,
				math.max(LevelMappings.LEVER_BOUNDS.CrestDip.sector_length.min, (params.sector_length or 0) - 4),
				true,
				{
					minHeight = params.height_or_depth or LevelMappings.LEVER_BOUNDS.CrestDip.height_or_depth.min,
					maxLength = params.sector_length or LevelMappings.LEVER_BOUNDS.CrestDip.sector_length.max,
				}
			)
			explanation = "crest too gentle; sharpened the curve"
		elseif string.find(hintsText, "vertical displacement", 1, true) then
			appendCrestTuneCandidates(
				candidates,
				params,
				(params.height_or_depth or 0) + 2,
				(params.sector_length or 0),
				true,
				{
					minHeight = params.height_or_depth or LevelMappings.LEVER_BOUNDS.CrestDip.height_or_depth.min,
				}
			)
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBoost(state.pads.ingress) })
			explanation = "crest or dip is too subtle; raised the peak"
		elseif string.find(hintsText, "reacquire", 1, true)
			or string.find(hintsText, "reacquisition", 1, true) then
			table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBrake(state.pads.ingress) })
			table.insert(candidates, { type = "SetPad", pad = "egress", value = weakerBrake(state.pads.egress) })
			appendCrestTuneCandidates(
				candidates,
				params,
				math.max(crestHeightFloor(), (params.height_or_depth or 0) - 2),
				math.min(sectorLengthCap, (params.sector_length or 0) + 8),
				false,
				{
					maxHeight = params.height_or_depth or LevelMappings.LEVER_BOUNDS.CrestDip.height_or_depth.max,
					minLength = params.sector_length or LevelMappings.LEVER_BOUNDS.CrestDip.sector_length.min,
				}
			)
			explanation = "reacquisition unstable; slowed entry and softened the landing"
		elseif failure.type == "local_execution_failure" then
			local progress = (packet.run_result.metrics.target_progress or 0)
			if unstableCrash then
				table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBrake(state.pads.ingress) })
				appendCrestTuneCandidates(
					candidates,
					params,
					math.max(crestHeightFloor(), (params.height_or_depth or 0) - softenHeightDelta),
					math.min(sectorLengthCap, (params.sector_length or 0) + softenLengthDelta),
					true,
					{
						maxHeight = params.height_or_depth or LevelMappings.LEVER_BOUNDS.CrestDip.height_or_depth.max,
						minLength = params.sector_length or LevelMappings.LEVER_BOUNDS.CrestDip.sector_length.min,
					}
				)
				table.insert(candidates, { type = "SetPad", pad = "egress", value = weakerBrake(state.pads.egress) })
				explanation = "crest entry was unstable; braking earlier and flattening the feature"
			elseif stalledOnCrest then
				table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBoost(state.pads.ingress) })
				appendCrestTuneCandidates(
					candidates,
					params,
					math.max(crestHeightFloor(), (params.height_or_depth or 0) - softenHeightDelta),
					math.min(sectorLengthCap, (params.sector_length or 0) + softenLengthDelta),
					true,
					{
						maxHeight = params.height_or_depth or LevelMappings.LEVER_BOUNDS.CrestDip.height_or_depth.max,
						minLength = params.sector_length or LevelMappings.LEVER_BOUNDS.CrestDip.sector_length.min,
					}
				)
				table.insert(candidates, { type = "SetPad", pad = "egress", value = weakerBrake(state.pads.egress) })
				explanation = "crest climb bled off too much speed; boosted entry and lowered the peak"
			elseif progress < 0.30 then
				table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBrake(state.pads.ingress) })
				appendCrestTuneCandidates(
					candidates,
					params,
					math.max(crestHeightFloor(), (params.height_or_depth or 0) - softenHeightDelta),
					math.min(sectorLengthCap, (params.sector_length or 0) + softenLengthDelta),
					true,
					{
						maxHeight = params.height_or_depth or LevelMappings.LEVER_BOUNDS.CrestDip.height_or_depth.max,
						minLength = params.sector_length or LevelMappings.LEVER_BOUNDS.CrestDip.sector_length.min,
					}
				)
				table.insert(candidates, { type = "SetPad", pad = "egress", value = weakerBrake(state.pads.egress) })
				explanation = "crest entry was overloaded; braking earlier and softening geometry first"
			else
				table.insert(candidates, { type = "SetPad", pad = "ingress", value = strongerBrake(state.pads.ingress) })
				appendCrestTuneCandidates(
					candidates,
					params,
					math.max(crestHeightFloor(), (params.height_or_depth or 0) - softenHeightDelta),
					math.min(sectorLengthCap, (params.sector_length or 0) + softenLengthDelta),
					true,
					{
						maxHeight = params.height_or_depth or LevelMappings.LEVER_BOUNDS.CrestDip.height_or_depth.max,
						minLength = params.sector_length or LevelMappings.LEVER_BOUNDS.CrestDip.sector_length.min,
					}
				)
				table.insert(candidates, { type = "SetPad", pad = "egress", value = weakerBrake(state.pads.egress) })
				explanation = "the crest remained unstable through the feature; slowed entry and softened it"
			end
		else
			appendCrestTuneCandidates(
				candidates,
				params,
				(params.height_or_depth or 0) + 1,
				math.min(sectorLengthCap, (params.sector_length or 0) + 4),
				true,
				nil
			)
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
