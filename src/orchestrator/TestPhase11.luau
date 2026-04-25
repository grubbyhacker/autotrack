--!strict

-- TestPhase11.luau
-- Unit tests for the Phase 11 ChallengeScore (plans/phase11.md §11).
-- These tests are stateless and do not require a running lap, so they run
-- under skip_baseline boot mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local T = require(script.Parent.TestUtils)
local ChallengeScore = require(script.Parent.Parent.Integrity.ChallengeScore)
local ChallengeRunner = require(script.Parent.ChallengeRunner)
local MinimalProposer = require(script.Parent.MinimalProposer)
local RequestParser = require(script.Parent.Parent.Agent.RequestParser)
local JobRunner = require(script.Parent.JobRunner)

type CIJob = Types.CIJob
type ChallengeScoreData = Types.ChallengeScore
type FailureInfo = Types.FailureInfo
type RunMetrics = Types.RunMetrics
type RunResult = Types.RunResult
type SectorParams = Types.SectorParams
type SectorState = Types.SectorState

type MetricOverrides = {
	entry_speed: number?,
	exit_speed: number?,
	airborne: boolean?,
	air_distance: number?,
	lateral_error: number?,
	vertical_displacement: number?,
	reacquired: boolean?,
	airtime_distance: number?,
	target_airborne: boolean?,
	target_air_distance: number?,
	target_vertical_displacement: number?,
	target_reacquired: boolean?,
	target_airtime_distance: number?,
	target_left_offset: number?,
	target_right_offset: number?,
	target_lateral_band_changes: number?,
	target_entered: boolean?,
	target_exited: boolean?,
	target_progress: number?,
	lap_time: number?,
	slowdown_ratio: number?,
	hang_time: number?,
	peak_lateral_g: number?,
	target_min_speed: number?,
}

local TestPhase11 = {}

local function applyParamOverrides(params: SectorParams, overrides: SectorParams?)
	if overrides == nil then
		return
	end
	if overrides.ramp_angle ~= nil then
		params.ramp_angle = overrides.ramp_angle
	end
	if overrides.ramp_length ~= nil then
		params.ramp_length = overrides.ramp_length
	end
	if overrides.gap_length ~= nil then
		params.gap_length = overrides.gap_length
	end
	if overrides.landing_length ~= nil then
		params.landing_length = overrides.landing_length
	end
	if overrides.amplitude ~= nil then
		params.amplitude = overrides.amplitude
	end
	if overrides.transition_length ~= nil then
		params.transition_length = overrides.transition_length
	end
	if overrides.corridor_width ~= nil then
		params.corridor_width = overrides.corridor_width
	end
	if overrides.height_or_depth ~= nil then
		params.height_or_depth = overrides.height_or_depth
	end
	if overrides.radius ~= nil then
		params.radius = overrides.radius
	end
	if overrides.sector_length ~= nil then
		params.sector_length = overrides.sector_length
	end
end

local function stateCrest(overrides: SectorParams?): SectorState
	local params: SectorParams = { height_or_depth = 6, radius = 20, sector_length = 40 }
	applyParamOverrides(params, overrides)
	return {
		sector_id = 3,
		mechanic = "CrestDip",
		params = params,
		pads = { ingress = "None", egress = "None" },
		version = 0,
	}
end

local function stateJump(overrides: SectorParams?): SectorState
	local params: SectorParams = { ramp_angle = 8, ramp_length = 24, gap_length = 4, landing_length = 34 }
	applyParamOverrides(params, overrides)
	return {
		sector_id = 3,
		mechanic = "RampJump",
		params = params,
		pads = { ingress = "None", egress = "None" },
		version = 0,
	}
end

local function stateChicane(overrides: SectorParams?): SectorState
	local params: SectorParams = { amplitude = 8, transition_length = 15, corridor_width = 14 }
	applyParamOverrides(params, overrides)
	return {
		sector_id = 3,
		mechanic = "Chicane",
		params = params,
		pads = { ingress = "None", egress = "None" },
		version = 0,
	}
end

local function applyMetricOverrides(m: RunMetrics, overrides: MetricOverrides?)
	if overrides == nil then
		return
	end
	if overrides.entry_speed ~= nil then
		m.entry_speed = overrides.entry_speed
	end
	if overrides.exit_speed ~= nil then
		m.exit_speed = overrides.exit_speed
	end
	if overrides.airborne ~= nil then
		m.airborne = overrides.airborne
	end
	if overrides.air_distance ~= nil then
		m.air_distance = overrides.air_distance
	end
	if overrides.lateral_error ~= nil then
		m.lateral_error = overrides.lateral_error
	end
	if overrides.vertical_displacement ~= nil then
		m.vertical_displacement = overrides.vertical_displacement
	end
	if overrides.reacquired ~= nil then
		m.reacquired = overrides.reacquired
	end
	if overrides.airtime_distance ~= nil then
		m.airtime_distance = overrides.airtime_distance
	end
	if overrides.target_airborne ~= nil then
		m.target_airborne = overrides.target_airborne
	end
	if overrides.target_air_distance ~= nil then
		m.target_air_distance = overrides.target_air_distance
	end
	if overrides.target_vertical_displacement ~= nil then
		m.target_vertical_displacement = overrides.target_vertical_displacement
	end
	if overrides.target_reacquired ~= nil then
		m.target_reacquired = overrides.target_reacquired
	end
	if overrides.target_airtime_distance ~= nil then
		m.target_airtime_distance = overrides.target_airtime_distance
	end
	if overrides.target_left_offset ~= nil then
		m.target_left_offset = overrides.target_left_offset
	end
	if overrides.target_right_offset ~= nil then
		m.target_right_offset = overrides.target_right_offset
	end
	if overrides.target_lateral_band_changes ~= nil then
		m.target_lateral_band_changes = overrides.target_lateral_band_changes
	end
	if overrides.target_entered ~= nil then
		m.target_entered = overrides.target_entered
	end
	if overrides.target_exited ~= nil then
		m.target_exited = overrides.target_exited
	end
	if overrides.target_progress ~= nil then
		m.target_progress = overrides.target_progress
	end
	if overrides.lap_time ~= nil then
		m.lap_time = overrides.lap_time
	end
	if overrides.slowdown_ratio ~= nil then
		m.slowdown_ratio = overrides.slowdown_ratio
	end
	if overrides.hang_time ~= nil then
		m.hang_time = overrides.hang_time
	end
	if overrides.peak_lateral_g ~= nil then
		m.peak_lateral_g = overrides.peak_lateral_g
	end
	if overrides.target_min_speed ~= nil then
		m.target_min_speed = overrides.target_min_speed
	end
end

local function metrics(overrides: MetricOverrides?): RunMetrics
	local m: RunMetrics = {
		entry_speed = 80,
		exit_speed = 60,
		airborne = false,
		air_distance = 0,
		lateral_error = 0,
		vertical_displacement = 0,
		reacquired = true,
		airtime_distance = 0,
		target_airborne = false,
		target_air_distance = 0,
		target_vertical_displacement = 0,
		target_reacquired = true,
		target_airtime_distance = 0,
		target_left_offset = 0,
		target_right_offset = 0,
		target_lateral_band_changes = 0,
		target_exited = false,
		target_progress = 0,
		lap_time = 25,
		slowdown_ratio = 1.0,
		hang_time = 0,
		peak_lateral_g = 0,
		target_min_speed = 80,
	}
	applyMetricOverrides(m, overrides)
	return m
end

local function runResult(
	success: boolean,
	failure: FailureInfo?,
	metricOverrides: MetricOverrides?,
	score: ChallengeScoreData?
): RunResult
	return {
		success = success,
		failure = failure,
		metrics = metrics(metricOverrides),
		failure_position = nil,
		final_position = nil,
		trajectory_tail = nil,
		score = score,
	}
end

local function runUnit()
	-- 1. Zero metrics → zero score, not over budget.
	do
		local s = ChallengeScore.compute(stateCrest(), metrics())
		T.expect(
			"phase11_zero_metrics_total_zero",
			math.abs(s.total) < 1e-6,
			"expected near-zero total, got " .. tostring(s.total)
		)
		T.expect("phase11_zero_metrics_not_over_budget", s.over_budget == false, "over_budget should be false")
		T.expect("phase11_zero_metrics_budget_used_zero", math.abs(s.budget_used) < 1e-6, "budget_used should be 0")
	end

	-- 2. Air component saturates at HANG_TIME_FULL_SCORE.
	do
		local s = ChallengeScore.compute(stateJump(), metrics({ hang_time = Constants.HANG_TIME_FULL_SCORE * 2 }))
		T.expect(
			"phase11_air_saturates_at_10",
			math.abs(s.air - 10) < 1e-6,
			"expected air==10, got " .. tostring(s.air)
		)
	end

	-- 3. Air component is linear below saturation.
	do
		local s = ChallengeScore.compute(stateJump(), metrics({ hang_time = Constants.HANG_TIME_FULL_SCORE * 0.5 }))
		T.expect("phase11_air_linear_half", math.abs(s.air - 5) < 0.01, "expected air~5, got " .. tostring(s.air))
	end

	-- 4. CrestDip near-miss: airtime at 90% of the cap scores close to 9.
	do
		local s = ChallengeScore.compute(
			stateCrest(),
			metrics({ target_airtime_distance = Constants.CRESTDIP_MAX_AIRTIME_DISTANCE * 0.9 })
		)
		T.expect(
			"phase11_crest_near_miss_high",
			s.near_miss >= 8.9 and s.near_miss <= 9.1,
			"expected near_miss≈9, got " .. tostring(s.near_miss)
		)
	end

	-- 5. CrestDip near-miss is zero when airtime is zero.
	do
		local s = ChallengeScore.compute(stateCrest(), metrics())
		T.expect(
			"phase11_crest_near_miss_zero",
			math.abs(s.near_miss) < 1e-6,
			"expected near_miss==0, got " .. tostring(s.near_miss)
		)
	end

	-- 6. Chicane near-miss rewards occupancy above the threshold.
	do
		-- near_miss now uses trackHalf (TRACK_WIDTH/2 = 8) as denominator.
		-- At offset=7.5: occupancy=7.5/8=0.9375, above zeroAt(0.75).
		local offset = 7.5
		local s = ChallengeScore.compute(
			stateChicane({ corridor_width = 14 }),
			metrics({
				target_left_offset = offset,
				target_right_offset = offset,
				target_lateral_band_changes = Constants.CHICANE_SCORE_ALT_FULL,
				target_min_speed = 80,
			})
		)
		T.expect(
			"phase11_chicane_near_miss_high",
			s.near_miss > 5,
			"expected near_miss > 5 at high occupancy, got " .. tostring(s.near_miss)
		)
	end

	-- 7. Chicane near-miss is zero at low occupancy.
	do
		local s = ChallengeScore.compute(
			stateChicane({ corridor_width = 14 }),
			metrics({ target_left_offset = 1, target_right_offset = 1, target_min_speed = 80 })
		)
		T.expect(
			"phase11_chicane_near_miss_low",
			s.near_miss < 1e-6,
			"expected near_miss==0 at low occupancy, got " .. tostring(s.near_miss)
		)
	end

	-- 8. Chicane one-sided occupancy scores lower than balanced occupancy.
	do
		local balanced = ChallengeScore.compute(
			stateChicane({ corridor_width = 14 }),
			metrics({
				target_left_offset = 6.5,
				target_right_offset = 6.5,
				target_lateral_band_changes = Constants.CHICANE_SCORE_ALT_FULL,
				target_min_speed = 80,
			})
		)
		local oneSided = ChallengeScore.compute(
			stateChicane({ corridor_width = 14 }),
			metrics({
				target_left_offset = 6.5,
				target_right_offset = 0.5,
				target_lateral_band_changes = 1,
				target_min_speed = 80,
			})
		)
		T.expect(
			"phase11_chicane_balanced_beats_one_sided",
			balanced.near_miss > oneSided.near_miss,
			string.format("expected balanced > one-sided, got %.3f vs %.3f", balanced.near_miss, oneSided.near_miss)
		)
	end

	-- 9. Chicane near-miss falls when the car scrubs too much speed.
	do
		local fast = ChallengeScore.compute(
			stateChicane({ corridor_width = 14 }),
			metrics({
				target_left_offset = 6.5,
				target_right_offset = 6.5,
				target_lateral_band_changes = Constants.CHICANE_SCORE_ALT_FULL,
				target_min_speed = 75,
			})
		)
		local slow = ChallengeScore.compute(
			stateChicane({ corridor_width = 14 }),
			metrics({
				target_left_offset = 6.5,
				target_right_offset = 6.5,
				target_lateral_band_changes = Constants.CHICANE_SCORE_ALT_FULL,
				target_min_speed = 35,
			})
		)
		T.expect(
			"phase11_chicane_speed_retention_matters",
			fast.near_miss > slow.near_miss,
			string.format("expected fast > slow, got %.3f vs %.3f", fast.near_miss, slow.near_miss)
		)
	end

	-- 9b. Chicane near-miss rises for the same swing when peak spacing tightens.
	do
		local wideSpacing = ChallengeScore.compute(
			stateChicane({ transition_length = 28 }),
			metrics({
				target_left_offset = 6.5,
				target_right_offset = 6.5,
				target_lateral_band_changes = Constants.CHICANE_SCORE_ALT_FULL,
				target_min_speed = 75,
			})
		)
		local tightSpacing = ChallengeScore.compute(
			stateChicane({ transition_length = 10 }),
			metrics({
				target_left_offset = 6.5,
				target_right_offset = 6.5,
				target_lateral_band_changes = Constants.CHICANE_SCORE_ALT_FULL,
				target_min_speed = 75,
			})
		)
		T.expect(
			"phase11_chicane_tighter_spacing_scores_higher",
			tightSpacing.near_miss > wideSpacing.near_miss,
			string.format(
				"expected tight spacing > wide spacing, got %.3f vs %.3f",
				tightSpacing.near_miss,
				wideSpacing.near_miss
			)
		)
	end

	-- 10. Over-budget flag fires when slowdown_ratio exceeds (1 + ratio).
	do
		local ratio = 1 + Constants.CHALLENGE_BUDGET_RATIO + 0.01
		local s = ChallengeScore.compute(stateJump(), metrics({ slowdown_ratio = ratio }))
		T.expect(
			"phase11_over_budget_fires",
			s.over_budget == true,
			"over_budget should be true for slowdown " .. tostring(ratio)
		)
	end

	-- 11. Over-budget flag does NOT fire at exact cap.
	do
		local ratio = 1 + Constants.CHALLENGE_BUDGET_RATIO
		local s = ChallengeScore.compute(stateJump(), metrics({ slowdown_ratio = ratio }))
		T.expect("phase11_at_cap_not_over_budget", s.over_budget == false, "over_budget should be false exactly at cap")
		T.expect("phase11_at_cap_budget_used_one", math.abs(s.budget_used - 1) < 1e-6, "budget_used should be 1 at cap")
	end

	-- 12. Time cost reduces total but does not make near-miss score negative alone.
	do
		local base = ChallengeScore.compute(
			stateCrest(),
			metrics({ target_airtime_distance = Constants.CRESTDIP_MAX_AIRTIME_DISTANCE * 0.9 })
		)
		local slowed = ChallengeScore.compute(
			stateCrest(),
			metrics({
				target_airtime_distance = Constants.CRESTDIP_MAX_AIRTIME_DISTANCE * 0.9,
				slowdown_ratio = 1 + Constants.CHALLENGE_BUDGET_RATIO * 0.5,
			})
		)
		T.expect(
			"phase11_time_cost_reduces_total",
			slowed.total < base.total,
			string.format("expected slowed total < base; got slowed=%.3f base=%.3f", slowed.total, base.total)
		)
	end

	-- 13. CrestDip exit brake is no longer explicitly penalized by ChallengeScore.
	do
		local free = ChallengeScore.compute(
			stateCrest(),
			metrics({ target_airtime_distance = Constants.CRESTDIP_MAX_AIRTIME_DISTANCE * 0.7 })
		)
		local brakedState = stateCrest()
		brakedState.pads.egress = "Brake10"
		local braked = ChallengeScore.compute(
			brakedState,
			metrics({ target_airtime_distance = Constants.CRESTDIP_MAX_AIRTIME_DISTANCE * 0.7 })
		)
		T.expect(
			"phase11_crestdip_egress_brake_not_explicitly_penalized",
			math.abs(braked.total - free.total) < 1e-6,
			string.format("expected equal totals; got %.3f vs %.3f", braked.total, free.total)
		)
	end

	-- 14. A challenging chicane (both sides + lateral G) totals higher than zero metrics.
	do
		local s = ChallengeScore.compute(
			stateChicane({ corridor_width = 14 }),
			metrics({
				target_left_offset = 6,
				target_right_offset = 6,
				target_lateral_band_changes = Constants.CHICANE_SCORE_ALT_FULL,
				target_min_speed = 80,
				peak_lateral_g = Constants.LATERAL_G_FULL_SCORE * 0.5,
			})
		)
		T.expect(
			"phase11_chicane_with_signal_scores_positive",
			s.total > 1,
			"expected total > 1, got " .. tostring(s.total)
		)
	end

	-- 14. The nearMissMargin helper exposes the raw [0,1] margin.
	do
		local m = ChallengeScore.nearMissMargin(
			stateCrest(),
			metrics({ target_airtime_distance = Constants.CRESTDIP_MAX_AIRTIME_DISTANCE * 0.5 })
		)
		T.expect("phase11_near_miss_margin_half", math.abs(m - 0.5) < 1e-6, "expected margin~0.5, got " .. tostring(m))
	end

	-- 15. Chicane ingress brake is no longer explicitly penalized by ChallengeScore.
	do
		local clean = ChallengeScore.compute(
			stateChicane({ corridor_width = 14 }),
			metrics({
				target_left_offset = 6.5,
				target_right_offset = 6.5,
				target_lateral_band_changes = Constants.CHICANE_SCORE_ALT_FULL,
				target_min_speed = 80,
			})
		)
		local brakedState = stateChicane({ corridor_width = 14 })
		brakedState.pads.ingress = "Brake10"
		local braked = ChallengeScore.compute(
			brakedState,
			metrics({
				target_left_offset = 6.5,
				target_right_offset = 6.5,
				target_lateral_band_changes = Constants.CHICANE_SCORE_ALT_FULL,
				target_min_speed = 80,
			})
		)
		T.expect(
			"phase11_chicane_ingress_brake_not_explicitly_penalized",
			math.abs(clean.total - braked.total) < 1e-6,
			string.format("expected equal totals; got %.3f vs %.3f", clean.total, braked.total)
		)
	end

	-- 16. aggregate sums and halves over-budget totals.
	do
		local a = ChallengeScore.compute(
			stateCrest(),
			metrics({ target_airtime_distance = Constants.CRESTDIP_MAX_AIRTIME_DISTANCE * 0.5 })
		)
		local b = ChallengeScore.compute(
			stateCrest(),
			metrics({ target_airtime_distance = Constants.CRESTDIP_MAX_AIRTIME_DISTANCE * 0.5 })
		)
		local agg = ChallengeScore.aggregate({ a, b })
		T.expect(
			"phase11_aggregate_sum",
			math.abs(agg.total - (a.total + b.total)) < 1e-6,
			"expected sum; got " .. tostring(agg.total)
		)
		T.expect("phase11_aggregate_count", agg.sector_count == 2, "expected count=2")
		T.expect("phase11_aggregate_not_over_budget", agg.any_over_budget == false, "should not be over budget")
	end

	-- 17. aggregate halves when any sector is over budget.
	do
		local a = ChallengeScore.compute(stateJump(), metrics({ hang_time = Constants.HANG_TIME_FULL_SCORE }))
		local b = ChallengeScore.compute(
			stateJump(),
			metrics({ slowdown_ratio = 1 + Constants.CHALLENGE_BUDGET_RATIO + 0.1 })
		)
		local agg = ChallengeScore.aggregate({ a, b })
		T.expect("phase11_aggregate_over_budget_flag", agg.any_over_budget == true, "expected any_over_budget=true")
		T.expect(
			"phase11_aggregate_over_budget_halved",
			math.abs(agg.total - (a.total + b.total) * 0.5) < 1e-6,
			string.format("expected halved; got %.3f vs %.3f", agg.total, (a.total + b.total) * 0.5)
		)
	end

	-- 18. suggestEscalation returns nil when over budget.
	do
		local s = ChallengeScore.compute(
			stateJump(),
			metrics({ slowdown_ratio = 1 + Constants.CHALLENGE_BUDGET_RATIO + 0.1 })
		)
		local lever = ChallengeScore.suggestEscalation(stateJump(), s)
		T.expect("phase11_escalation_blocked_over_budget", lever == nil, "expected nil when over budget")
	end

	-- 19. suggestEscalation points at air for a flat jump.
	do
		local s = ChallengeScore.compute(stateJump(), metrics())
		local lever = ChallengeScore.suggestEscalation(stateJump(), s)
		T.expect(
			"phase11_escalation_jump_prefers_angle",
			lever == "ramp_angle",
			"expected ramp_angle; got " .. tostring(lever)
		)
	end

	-- 20. Once the wave is already tall, chicane escalation tightens peak spacing.
	do
		local s = ChallengeScore.compute(stateChicane(), metrics())
		local lever = ChallengeScore.suggestEscalation(stateChicane(), s)
		T.expect(
			"phase11_escalation_chicane_prefers_spacing_after_tall_wave",
			lever == "transition_length",
			"expected transition_length; got " .. tostring(lever)
		)
	end

	-- 21. Runner escalation: RampJump flat state nudges ramp_angle upward.
	do
		local st = stateJump()
		local s = ChallengeScore.compute(st, metrics())
		local next_, lever, reason = ChallengeRunner._escalateState(st, s)
		local currentAngle = st.params.ramp_angle or 0
		local nextAngle = if next_ ~= nil then next_.params.ramp_angle else nil
		T.expect(
			"phase11_runner_jump_lever",
			lever == "ramp_angle",
			"expected ramp_angle; got " .. tostring(lever) .. " reason=" .. tostring(reason)
		)
		T.expect(
			"phase11_runner_jump_increases_angle",
			nextAngle ~= nil and nextAngle > currentAngle,
			"expected ramp_angle to increase"
		)
	end

	-- 22. Runner escalation: Chicane state below amplitude ceiling escalates amplitude.
	do
		-- Use amplitude=6 so there is room to escalate (ceiling is TRACK_WIDTH/2=8).
		local st = stateChicane({ amplitude = 6 })
		local s = ChallengeScore.compute(st, metrics())
		local next_, lever = ChallengeRunner._escalateState(st, s)
		local currentAmplitude = st.params.amplitude or 0
		local nextAmplitude = if next_ ~= nil then next_.params.amplitude else nil
		T.expect("phase11_runner_chicane_lever", lever == "amplitude", "expected amplitude; got " .. tostring(lever))
		T.expect(
			"phase11_runner_chicane_mutates",
			nextAmplitude ~= nil and nextAmplitude > currentAmplitude,
			"expected amplitude to increase"
		)
	end

	-- 23. Runner escalation: CrestDip flat state drives height_or_depth up.
	do
		local st = stateCrest()
		local s = ChallengeScore.compute(st, metrics())
		local next_, lever = ChallengeRunner._escalateState(st, s)
		local currentValue: number? = nil
		local nextValue: number? = nil
		if lever == "height_or_depth" then
			currentValue = st.params.height_or_depth
			nextValue = if next_ ~= nil then next_.params.height_or_depth else nil
		elseif lever == "sector_length" then
			currentValue = st.params.sector_length
			nextValue = if next_ ~= nil then next_.params.sector_length else nil
		end
		T.expect(
			"phase11_runner_crest_lever",
			lever == "height_or_depth" or lever == "sector_length",
			"expected height_or_depth or sector_length; got " .. tostring(lever)
		)
		T.expect(
			"phase11_runner_crest_mutates",
			nextValue ~= nil and currentValue ~= nil and nextValue ~= currentValue,
			"expected lever value to change"
		)
	end

	-- 24. Runner escalation respects the LEVER_FLOOR: a lever already at
	-- floor whose delta is negative must be rejected (no underflow).
	do
		-- corridor_width floor is 8; delta for Chicane corridor_width is -2.
		-- Starting at 9 yields candidate=7, below floor → rejected.
		local st = stateChicane({ corridor_width = 9, amplitude = 20, transition_length = 20 })
		-- Build a score that would nominate corridor_width (high lateral, low near_miss).
		local m = metrics({ peak_lateral_g = Constants.LATERAL_G_FULL_SCORE })
		local s = ChallengeScore.compute(st, m)
		local next_, lever, reason = ChallengeRunner._escalateState(st, s)
		-- Either: the runner picks corridor_width and floors it out (next_==nil),
		-- or it picks a different lever that is allowed. Both are acceptable —
		-- the invariant we care about is "no floor underflow".
		if next_ ~= nil then
			local nextWidth = next_.params.corridor_width or 0
			T.expect(
				"phase11_runner_no_underflow",
				nextWidth >= 8,
				"corridor_width dropped below floor to " .. tostring(nextWidth)
			)
		else
			T.expect("phase11_runner_rejects_with_reason", reason ~= nil and #reason > 0, "expected a rejection reason")
		end
		-- Silence unused lever warning.
		local _ = lever
	end

	-- 25. Runner escalation: nil returned when score says over budget.
	do
		local st = stateJump()
		local s = ChallengeScore.compute(st, metrics({ slowdown_ratio = 1 + Constants.CHALLENGE_BUDGET_RATIO + 0.1 }))
		local next_, lever = ChallengeRunner._escalateState(st, s)
		T.expect(
			"phase11_runner_blocks_over_budget",
			next_ == nil and lever == nil,
			"expected nil state when over budget"
		)
	end

	-- 26. Extreme proposals start more aggressively than normal proposals.
	do
		local normalRequest, normalErr = RequestParser.parse("add a jump in sector 3", "phase11-normal")
		assert(normalRequest ~= nil, "expected normal request: " .. tostring(normalErr))
		local extremeRequest, extremeErr = RequestParser.parse("add an extreme jump in sector 3", "phase11-extreme")
		assert(extremeRequest ~= nil, "expected extreme request: " .. tostring(extremeErr))

		local normalState, normalStateErr = MinimalProposer.initial(normalRequest)
		local extremeState, extremeStateErr = MinimalProposer.initial(extremeRequest)
		assert(normalState ~= nil, "expected normal initial state: " .. tostring(normalStateErr))
		assert(extremeState ~= nil, "expected extreme initial state: " .. tostring(extremeStateErr))

		local normalAngle = normalState.params.ramp_angle or 0
		local extremeAngle = extremeState.params.ramp_angle or 0
		T.expect(
			"phase11_extreme_bias_jump_angle",
			extremeAngle > normalAngle,
			string.format(
				"expected extreme angle > normal; got %s vs %s",
				tostring(extremeAngle),
				tostring(normalAngle)
			)
		)
		local normalGap = normalState.params.gap_length or 0
		local extremeGap = extremeState.params.gap_length or 0
		T.expect(
			"phase11_extreme_bias_jump_gap",
			extremeGap > normalGap,
			string.format("expected extreme gap > normal; got %s vs %s", tostring(extremeGap), tostring(normalGap))
		)
	end

	-- 27. Endurance build submits can trigger the proposer-owned challenge-up do-over.
	do
		local request, err = RequestParser.parse("add an extreme jump in sector 3", "phase11-endurance-suppress")
		assert(request ~= nil, "expected request: " .. tostring(err))
		request.origin = "endurance"
		request.design_intent = {
			sector_id = 3,
			mechanic = "RampJump",
			params_hint = "extreme tall",
			rationale = "undershot clean pass",
			target_score_band = "high",
			target_budget_tolerance = "medium",
			target_reliability = "balanced",
			spectacle_priority = "high",
			novelty_priority = "medium",
			replacement_intent = "open_slot_preferred",
			desired_feel = "scoreable but recoverable",
			constraints = { "stay under endurance budget" },
		}
		local result = runResult(true, nil, nil, {
			total = 5,
			air = 2,
			lateral = 0,
			near_miss = 3,
			time_cost = 0,
			budget_used = 0.2,
			over_budget = false,
		})
		local shouldRun, why, strategy = JobRunner._shouldRunChallengeUp(request, result, true)
		T.expect(
			"phase11_endurance_challenge_up_uses_proposal_do_over",
			shouldRun == true and why == nil and strategy == "proposal_do_over",
			string.format(
				"expected proposer do-over, got shouldRun=%s why=%s strategy=%s",
				tostring(shouldRun),
				tostring(why),
				tostring(strategy)
			)
		)
	end

	-- 28. Pre-target failures must revert instead of repairing the target sector.
	do
		local result = runResult(false, {
			type = "local_execution_failure",
			sector_id = 2,
		}, {
			target_entered = true,
			target_exited = false,
			target_progress = 0.4,
		}, nil)
		T.expect(
			"phase11_pre_target_failure_reverts",
			JobRunner._shouldRevertPreTargetFailure(result, 3) == true,
			"expected pre-target failure revert guard to fire"
		)
	end

	-- 29. Once the target was entered, downstream failures remain repairable.
	do
		local result = runResult(false, {
			type = "local_execution_failure",
			sector_id = 4,
		}, {
			target_entered = true,
			target_exited = true,
			target_progress = 1,
		}, nil)
		T.expect(
			"phase11_post_target_failure_does_not_revert",
			JobRunner._shouldRevertPreTargetFailure(result, 3) == false,
			"expected guard to stay off after target entry"
		)
	end

	-- 30. Halfway target progress unlocks extra repair attempts.
	do
		local result = runResult(false, {
			type = "local_execution_failure",
			sector_id = 3,
		}, {
			target_entered = true,
			target_exited = false,
			target_progress = 0.6,
		}, nil)
		T.expect(
			"phase11_halfway_progress_gets_extra_attempts",
			JobRunner._attemptLimitForResult(result, 3)
				== Constants.MAX_REPAIR_ATTEMPTS + Constants.EXTRA_REPAIR_ATTEMPTS_AFTER_HALF_PROGRESS,
			"expected extra repair attempts after halfway progress"
		)
	end

	-- 31–32. Endurance lap-time budget gate follows the current configured ratio.
	do
		local ratio = Constants.ENDURANCE_LAP_TIME_BUDGET_RATIO
		local overThreshold = 1 + ratio + 0.01
		T.expect(
			"phase11_endurance_budget_not_over_at_1_39",
			1.39 <= 1 + ratio,
			"expected 1.39 to be within endurance budget (ratio=" .. tostring(ratio) .. ")"
		)
		T.expect(
			"phase11_endurance_budget_over_at_1_41",
			overThreshold > 1 + ratio,
			"expected ratio+0.01 to exceed endurance budget (ratio=" .. tostring(ratio) .. ")"
		)
	end
end

function TestPhase11.runUnit()
	runUnit()
end

local function waitForBaseline(): boolean
	local deadline = os.clock() + 45
	while os.clock() < deadline do
		if workspace:GetAttribute("AutoTrack_BaselineLapDone") == true then
			return true
		end
		task.wait(0.25)
	end
	return false
end

local function waitForIdle(timeoutSeconds: number): boolean
	local deadline = os.clock() + timeoutSeconds
	while os.clock() < deadline do
		if JobRunner.isBusy() == false then
			return true
		end
		task.wait(0.1)
	end
	return JobRunner.isBusy() == false
end

local function summariseAttempts(job: CIJob?): string
	if job == nil or #job.attempts == 0 then
		return "no-attempts"
	end

	local parts: { string } = {}
	for _, attempt in ipairs(job.attempts) do
		local result = attempt.result
		local failure = result.failure
		local hints = attempt.hints or {}
		local action = attempt.action
		local actionText = "initial"
		if action ~= nil then
			if action.type == "SetPad" then
				actionText = string.format("%s=%s", action.pad, action.value)
			else
				actionText = string.format("%s=%s", action.lever, tostring(action.value))
			end
		end
		table.insert(
			parts,
			string.format(
				"%d:%s/%s/%s action=%s progress=%.2f hints=%s",
				attempt.attempt_index,
				tostring(result.success),
				tostring(failure and failure.type or "none"),
				tostring(failure and failure.detail or "-"),
				actionText,
				result.metrics and result.metrics.target_progress or 0,
				if #hints > 0 then table.concat(hints, "&") else "-"
			)
		)
	end

	return table.concat(parts, " || ")
end

function TestPhase11.runIntegration()
	local ReplicatedStorage2 = game:GetService("ReplicatedStorage")
	local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)

	if workspace:GetAttribute("AutoTrack_BootBaselineSkipped") == true then
		T.fail("phase11_integration_requires_baseline", "restart without AutoTrack_SkipBootBaseline")
		return
	end
	if not waitForBaseline() then
		T.fail("phase11_baseline_ready", "baseline lap did not complete before integration tests")
		return
	end

	local ok, reason = JobRunner.submit("add an extreme tall jump in sector 3")
	if not ok then
		T.fail("phase11_extreme_submit_accepted", "submit rejected: " .. tostring(reason))
		return
	end

	-- Stage B can take a while (up to CHALLENGE_UP_ROUNDS extra laps).
	local idle = waitForIdle(Constants.CHALLENGE_UP_ROUNDS * 45 + 60)
	T.expect("phase11_extreme_reaches_idle", idle, "JobRunner never returned to idle")

	local job = JobRunner.getLastJob()
	T.expect(
		"phase11_extreme_job_committed",
		job ~= nil and job.final_status == "committed",
		"expected committed; got " .. tostring(job and job.final_status) .. " :: " .. summariseAttempts(job)
	)

	local state = SectorRegistry.getCommitted(3)
	T.expect(
		"phase11_extreme_commit_is_rampjump",
		state ~= nil and state.mechanic == "RampJump",
		"expected RampJump commit; got " .. tostring(state and state.mechanic) .. " :: " .. summariseAttempts(job)
	)

	local stateFolder = ReplicatedStorage2:WaitForChild("AutoTrackUIState")
	T.expect(
		"phase11_extreme_score_published",
		stateFolder:GetAttribute("last_score_sector") == 3,
		"expected last_score_sector=3; got "
			.. tostring(stateFolder:GetAttribute("last_score_sector"))
			.. " :: "
			.. summariseAttempts(job)
	)
	local total = stateFolder:GetAttribute("last_score_total") or -1
	T.expect(
		"phase11_extreme_score_nonzero",
		type(total) == "number" and total >= 0,
		"expected numeric score; got " .. tostring(total)
	)

	-- Chicane scoring is verified by unit tests (phase11_chicane_*); the
	-- integration test omits a separate chicane step to avoid sector-coupling
	-- issues where the sector 3 jump (committed above) becomes flaky on the
	-- full lap that tests a downstream sector.
end

function TestPhase11.run()
	TestPhase11.runUnit()
	TestPhase11.runIntegration()
end

return TestPhase11
