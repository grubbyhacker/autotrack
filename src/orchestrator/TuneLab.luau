local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local ChicanePath = require(script.Parent.Parent.Mechanics.ChicanePath)
local ChallengeScore = require(script.Parent.Parent.Integrity.ChallengeScore)

local TuneLab = {}

TuneLab.CAR_TARGET_SPEED_BOUNDS = {
	min = 60,
	max = 160,
}

local function rangedAttr(workspaceAttr: string, minValue: number, maxValue: number)
	return {
		workspace_attr = workspaceAttr,
		min = minValue,
		max = maxValue,
	}
end

TuneLab.ATTR_SPECS = {
	car_target_speed = rangedAttr("AutoTrack_CarTargetSpeed", 60, 160),
	sector_entry_snap_straight_speed_factor = rangedAttr("AutoTrack_SectorEntrySnapStraightSpeedFactor", 0.1, 2.0),
	sector_entry_snap_rampjump_speed_factor = rangedAttr("AutoTrack_SectorEntrySnapRampJumpSpeedFactor", 0.05, 1.5),
	sector_entry_snap_crestdip_speed_factor = rangedAttr("AutoTrack_SectorEntrySnapCrestDipSpeedFactor", 0.05, 1.5),
	sector_entry_snap_chicane_speed_factor = rangedAttr("AutoTrack_SectorEntrySnapChicaneSpeedFactor", 0.05, 1.5),
	sector_entry_snap_settle_time = rangedAttr("AutoTrack_SectorEntrySnapSettleTime", 0, 1.0),
	target_sector_stability_max_angular_speed = rangedAttr("AutoTrack_TargetSectorStabilityMaxAngularSpeed", 0, 40),
	target_sector_stability_max_vertical_speed = rangedAttr("AutoTrack_TargetSectorStabilityMaxVerticalSpeed", 0, 120),
	rampjump_target_sector_stability_max_angular_speed = rangedAttr("AutoTrack_RampJumpTargetSectorStabilityMaxAngularSpeed", 0, 20),
	rampjump_target_sector_stability_max_vertical_speed = rangedAttr("AutoTrack_RampJumpTargetSectorStabilityMaxVerticalSpeed", 0, 80),
	rampjump_airborne_max_upward_speed = rangedAttr("AutoTrack_RampJumpAirborneMaxUpwardSpeed", 0, 80),
	straight_pin_yaw_damping = rangedAttr("AutoTrack_StraightPinYawDamping", 0, 120),
	straight_pin_roll_damping = rangedAttr("AutoTrack_StraightPinRollDamping", 0, 120),
	straight_pin_orientation_max_torque = rangedAttr("AutoTrack_StraightPinOrientationMaxTorque", 0, 160000),
	straight_pin_orientation_responsiveness = rangedAttr("AutoTrack_StraightPinOrientationResponsiveness", 0, 80),
	rampjump_entry_speed_factor = rangedAttr("AutoTrack_RampJumpEntrySpeedFactor", 0.05, 1.5),
	crestdip_entry_speed_factor = rangedAttr("AutoTrack_CrestDipEntrySpeedFactor", 0.05, 1.5),
	post_corner_mechanic_entry_speed_factor = rangedAttr("AutoTrack_PostCornerMechanicEntrySpeedFactor", 0.05, 1.5),
	off_track_failure_distance = rangedAttr("AutoTrack_OffTrackFailureDistance", 6, 28),
	front_body_containment_distance = rangedAttr("AutoTrack_FrontBodyContainmentDistance", 6, 24),
	rampjump_min_vertical_displacement = rangedAttr("AutoTrack_RampJumpMinVerticalDisplacement", 0, 12),
	rampjump_reacquire_max = rangedAttr("AutoTrack_RampJumpReacquireMax", 2, 30),
	rampjump_comfort_vertical_margin = rangedAttr("AutoTrack_RampJumpComfortVerticalMargin", 0, 6),
	rampjump_comfort_reacquire_margin = rangedAttr("AutoTrack_RampJumpComfortReacquireMargin", 0, 12),
	rampjump_comfort_exit_max_angular_speed = rangedAttr("AutoTrack_RampJumpComfortExitMaxAngularSpeed", 0.25, 12),
	rampjump_comfort_exit_max_vertical_speed = rangedAttr("AutoTrack_RampJumpComfortExitMaxVerticalSpeed", 1, 30),
	rampjump_landing_min_up_dot = rangedAttr("AutoTrack_RampJumpLandingMinUpDot", 0.4, 1.0),
	rampjump_hard_landing_exit_max_angular_speed = rangedAttr("AutoTrack_RampJumpHardLandingExitMaxAngularSpeed", 0.25, 18),
	rampjump_hard_landing_exit_max_vertical_speed = rangedAttr("AutoTrack_RampJumpHardLandingExitMaxVerticalSpeed", 1, 40),
	rampjump_profile_mode = rangedAttr("AutoTrack_RampJumpProfileMode", 0, 1),
	chicane_min_lateral_displacement = rangedAttr("AutoTrack_ChicaneMinLateralDisplacement", 1, 12),
	chicane_min_alternations = rangedAttr("AutoTrack_ChicaneMinAlternations", 1, 5),
	chicane_min_curvature = rangedAttr("AutoTrack_ChicaneMinCurvature", 0.001, 0.5),
	chicane_comfort_lateral_margin = rangedAttr("AutoTrack_ChicaneComfortLateralMargin", 0, 6),
	chicane_comfort_body_margin = rangedAttr("AutoTrack_ChicaneComfortBodyMargin", 0, 6),
	crestdip_min_vertical_displacement = rangedAttr("AutoTrack_CrestDipMinVerticalDisplacement", 0, 12),
	crestdip_min_curvature = rangedAttr("AutoTrack_CrestDipMinCurvature", 0.001, 0.1),
	crestdip_max_airtime_distance = rangedAttr("AutoTrack_CrestDipMaxAirtimeDistance", 4, 60),
	crestdip_apex_min_speed = rangedAttr("AutoTrack_CrestDipApexMinSpeed", 0, 80),
	crestdip_comfort_vertical_margin = rangedAttr("AutoTrack_CrestDipComfortVerticalMargin", 0, 8),
	crestdip_comfort_airtime_margin = rangedAttr("AutoTrack_CrestDipComfortAirtimeMargin", 0, 20),
	crestdip_comfort_apex_speed_margin = rangedAttr("AutoTrack_CrestDipComfortApexSpeedMargin", 0, 20),
	crestdip_comfort_exit_max_angular_speed = rangedAttr("AutoTrack_CrestDipComfortExitMaxAngularSpeed", 0.25, 12),
	crestdip_comfort_exit_max_vertical_speed = rangedAttr("AutoTrack_CrestDipComfortExitMaxVerticalSpeed", 1, 24),
}

local EXPERIMENTAL_BOUNDS = {
	RampJump = {
		ramp_angle = { min = 2, max = 18 },
		ramp_length = { min = 12, max = 72 },
		gap_length = { min = 1, max = 24 },
		landing_length = { min = 12, max = 72 },
	},
	Chicane = {
		amplitude = { min = 1, max = 32 },
		transition_length = { min = 4, max = ChicanePath.maxTransitionLength() },
		corridor_width = { min = 4, max = Constants.TRACK_WIDTH },
	},
	CrestDip = {
		height_or_depth = { min = -30, max = 30 },
		radius = { min = 4, max = 60 },
		sector_length = { min = 12, max = Constants.STRAIGHT_LENGTH },
	},
}

local function cloneTable(source)
	local result = {}
	for key, value in pairs(source or {}) do
		if type(value) == "table" then
			result[key] = cloneTable(value)
		else
			result[key] = value
		end
	end
	return result
end

local function clampRounded(value: number, minValue: number, maxValue: number): number
	return math.clamp(math.round(value), minValue, maxValue)
end

local function targetBodyDistance(metrics): number
	if type(metrics.target_peak_body_distance) == "number" then
		return metrics.target_peak_body_distance
	end
	if type(metrics.sector_peak_body_distance) == "table" then
		local peak = 0
		for _, value in pairs(metrics.sector_peak_body_distance) do
			peak = math.max(peak, value or 0)
		end
		return peak
	end
	return 0
end

function TuneLab.experimentalBounds(mechanic: string)
	return cloneTable(EXPERIMENTAL_BOUNDS[mechanic] or {})
end

function TuneLab.formatBoundsSummary(mechanic: string): string
	local bounds = EXPERIMENTAL_BOUNDS[mechanic]
	if bounds == nil then
		return ""
	end

	local pieces = {}
	for lever, range in pairs(bounds) do
		table.insert(pieces, string.format("%s=[%s,%s]", lever, tostring(range.min), tostring(range.max)))
	end
	table.sort(pieces)
	return table.concat(pieces, " | ")
end

function TuneLab.normalizeLever(mechanic: string, lever: string, requestedValue: number, currentParams)
	local mechanicBounds = EXPERIMENTAL_BOUNDS[mechanic]
	local range = mechanicBounds and mechanicBounds[lever]
	if range == nil then
		return nil, string.format("missing experimental bounds for %s.%s", tostring(mechanic), tostring(lever))
	end

	local appliedMin = range.min
	local appliedMax = range.max
	if mechanic == "RampJump" and (lever == "ramp_length" or lever == "gap_length" or lever == "landing_length") then
		local rampLength = currentParams and currentParams.ramp_length or 0
		local gapLength = currentParams and currentParams.gap_length or 0
		local landingLength = currentParams and currentParams.landing_length or 0
		local otherTotal = 0
		if lever ~= "ramp_length" then
			otherTotal += rampLength
		end
		if lever ~= "gap_length" then
			otherTotal += gapLength
		end
		if lever ~= "landing_length" then
			otherTotal += landingLength
		end
		appliedMax = math.max(appliedMin, math.min(appliedMax, Constants.STRAIGHT_LENGTH - otherTotal))
	elseif mechanic == "Chicane" and lever == "transition_length" then
		appliedMax = math.min(appliedMax, ChicanePath.maxTransitionLength())
	elseif mechanic == "Chicane" and lever == "corridor_width" then
		appliedMax = math.min(appliedMax, Constants.TRACK_WIDTH)
	elseif mechanic == "CrestDip" and lever == "sector_length" then
		appliedMax = math.min(appliedMax, Constants.STRAIGHT_LENGTH)
	end

	return clampRounded(requestedValue, appliedMin, appliedMax), nil
end

function TuneLab.normalizeState(state)
	local normalized = {
		sector_id = state.sector_id,
		mechanic = state.mechanic,
		params = cloneTable(state.params),
		pads = cloneTable(state.pads),
		version = state.version,
	}
	local mechanic = normalized.mechanic
	local bounds = EXPERIMENTAL_BOUNDS[mechanic]
	if bounds == nil then
		return normalized
	end

	for lever, value in pairs(normalized.params) do
		if type(value) == "number" and bounds[lever] ~= nil then
			local clamped = TuneLab.normalizeLever(mechanic, lever, value, normalized.params)
			normalized.params[lever] = clamped
		end
	end

	return normalized
end

function TuneLab.productionChallengeScore(state, result)
	if state == nil or result == nil or result.success ~= true then
		return nil
	end
	if result.score ~= nil then
		return cloneTable(result.score)
	end
	return ChallengeScore.compute(state, result.metrics or {})
end

function TuneLab.clampTargetSpeed(value: number): number
	return clampRounded(value, TuneLab.CAR_TARGET_SPEED_BOUNDS.min, TuneLab.CAR_TARGET_SPEED_BOUNDS.max)
end

function TuneLab.normalizeAttr(name: string, value: number): number?
	local spec = TuneLab.ATTR_SPECS[name]
	if spec == nil then
		return nil
	end
	if name == "car_target_speed" then
		return TuneLab.clampTargetSpeed(value)
	end
	if type(spec.min) == "number" and type(spec.max) == "number" then
		return math.clamp(value, spec.min, spec.max)
	end
	return value
end

function TuneLab.scorePass(result): number
	local metrics = result.metrics or {}
	local successScore = if result.success then 1000 else 0
	local failurePenalty = 0
	if not result.success then
		local failureType = result.failure and result.failure.type or "system_failure"
		if failureType == "mechanic_integrity_failure" then
			failurePenalty = 420
		elseif failureType == "downstream_failure" then
			failurePenalty = 500
		elseif failureType == "local_execution_failure" then
			failurePenalty = 580
		else
			failurePenalty = 650
		end
	end

	local speedReward = (metrics.exit_speed or 0) + ((metrics.target_min_speed or 0) * 0.4) + ((metrics.target_apex_min_speed or 0) * 0.25)
	local reacquireBonus = if metrics.target_reacquired == false then -160 else if metrics.target_reacquired == true then 120 else 0
	local reacquireDistancePenalty = (metrics.target_reacquire_distance or 0) * 8
	local bodyPenalty = targetBodyDistance(metrics) * 26
	local angularPenalty = math.abs(metrics.target_exit_angular_speed or 0) * 40
	local verticalPenalty = math.abs(metrics.target_exit_vertical_speed or 0) * 7
	local slowdownPenalty = math.max(0, (metrics.slowdown_ratio or 1) - 1) * 120
	local lateralPenalty = math.abs(metrics.lateral_error or 0) * 10

	return successScore
		+ speedReward
		+ reacquireBonus
		- failurePenalty
		- reacquireDistancePenalty
		- bodyPenalty
		- angularPenalty
		- verticalPenalty
		- slowdownPenalty
		- lateralPenalty
end

function TuneLab.aggregateCandidate(records)
	local summary = {
		pass_count = #records,
		success_count = 0,
		failure_count = 0,
		average_score = 0,
		best_score = -math.huge,
		challenge_success_count = 0,
		average_challenge_total = 0,
		best_challenge_total = -math.huge,
		average_lap_time = 0,
		average_entry_speed = 0,
		average_exit_speed = 0,
		worst_body_distance = 0,
		last_failure = "",
		score = -math.huge,
	}
	if #records == 0 then
		summary.best_score = 0
		summary.best_challenge_total = 0
		summary.score = 0
		return summary
	end

	local totalScore = 0
	local totalChallenge = 0
	local totalLapTime = 0
	local totalEntry = 0
	local totalExit = 0
	for _, record in ipairs(records) do
		local score = record.score or 0
		local challengeTotal = if type(record.challenge_score) == "table" then (record.challenge_score.total or 0) else 0
		local metrics = record.metrics or {}
		totalScore += score
		totalChallenge += challengeTotal
		totalLapTime += metrics.lap_time or 0
		totalEntry += metrics.entry_speed or 0
		totalExit += metrics.exit_speed or 0
		summary.best_score = math.max(summary.best_score, score)
		summary.best_challenge_total = math.max(summary.best_challenge_total, challengeTotal)
		summary.worst_body_distance = math.max(summary.worst_body_distance, targetBodyDistance(metrics))
		if record.success then
			summary.success_count += 1
			if type(record.challenge_score) == "table" then
				summary.challenge_success_count += 1
			end
		else
			summary.failure_count += 1
			summary.last_failure = tostring(record.failure_detail or "")
		end
	end

	summary.average_score = totalScore / #records
	summary.average_challenge_total = totalChallenge / #records
	summary.average_lap_time = totalLapTime / #records
	summary.average_entry_speed = totalEntry / #records
	summary.average_exit_speed = totalExit / #records
	summary.score = summary.success_count * 1000 + summary.average_score - summary.failure_count * 200
	return summary
end

function TuneLab.compareAggregatePair(baselineResult, candidateResult)
	local baselineAggregate = baselineResult and baselineResult.aggregate or {}
	local candidateAggregate = candidateResult and candidateResult.aggregate or {}
	local baselineScore = baselineAggregate.score or 0
	local candidateScore = candidateAggregate.score or 0
	local baselineChallenge = baselineAggregate.average_challenge_total or 0
	local candidateChallenge = candidateAggregate.average_challenge_total or 0
	local baselineSuccess = baselineAggregate.success_count or 0
	local candidateSuccess = candidateAggregate.success_count or 0

	return {
		baseline_label = baselineResult and baselineResult.label or "baseline",
		candidate_label = candidateResult and candidateResult.label or "candidate",
		heuristic_delta = candidateScore - baselineScore,
		challenge_delta = candidateChallenge - baselineChallenge,
		success_delta = candidateSuccess - baselineSuccess,
		heuristic_winner = if candidateScore >= baselineScore
			then (candidateResult and candidateResult.label or "candidate")
			else (baselineResult and baselineResult.label or "baseline"),
		challenge_winner = if candidateChallenge >= baselineChallenge
			then (candidateResult and candidateResult.label or "candidate")
			else (baselineResult and baselineResult.label or "baseline"),
	}
end

return TuneLab
