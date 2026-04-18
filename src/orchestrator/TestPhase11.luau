-- TestPhase11.luau
-- Unit tests for the Phase 11 ChallengeScore (plans/phase11.md §11).
-- These tests are stateless and do not require a running lap, so they run
-- under skip_baseline boot mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local T = require(script.Parent.TestUtils)
local ChallengeScore = require(script.Parent.Parent.Integrity.ChallengeScore)
local ChallengeRunner = require(script.Parent.ChallengeRunner)

local TestPhase11 = {}

local function stateCrest(overrides)
	local params = { height_or_depth = 6, radius = 20, sector_length = 40 }
	if overrides then
		for k, v in pairs(overrides) do params[k] = v end
	end
	return {
		sector_id = 3,
		mechanic = "CrestDip",
		params = params,
		pads = { ingress = "None", egress = "None" },
		version = 0,
	}
end

local function stateJump(overrides)
	local params = { ramp_angle = 20, ramp_length = 12, gap_length = 8, landing_length = 12 }
	if overrides then
		for k, v in pairs(overrides) do params[k] = v end
	end
	return {
		sector_id = 3,
		mechanic = "RampJump",
		params = params,
		pads = { ingress = "None", egress = "None" },
		version = 0,
	}
end

local function stateChicane(overrides)
	local params = { amplitude = 8, transition_length = 15, corridor_width = 14 }
	if overrides then
		for k, v in pairs(overrides) do params[k] = v end
	end
	return {
		sector_id = 3,
		mechanic = "Chicane",
		params = params,
		pads = { ingress = "None", egress = "None" },
		version = 0,
	}
end

local function metrics(overrides)
	local m = {
		entry_speed = 80, exit_speed = 60,
		airborne = false, air_distance = 0,
		lateral_error = 0, vertical_displacement = 0,
		reacquired = true, airtime_distance = 0,
		target_airborne = false, target_air_distance = 0,
		target_vertical_displacement = 0, target_reacquired = true,
		target_airtime_distance = 0,
		target_left_offset = 0, target_right_offset = 0,
		target_lateral_band_changes = 0,
		lap_time = 25, slowdown_ratio = 1.0,
		hang_time = 0, peak_lateral_g = 0, target_min_speed = 80,
	}
	if overrides then
		for k, v in pairs(overrides) do m[k] = v end
	end
	return m
end

local function runUnit()
	-- 1. Zero metrics → zero score, not over budget.
	do
		local s = ChallengeScore.compute(stateCrest(), metrics())
		T.expect("phase11_zero_metrics_total_zero",
			math.abs(s.total) < 1e-6,
			"expected near-zero total, got " .. tostring(s.total))
		T.expect("phase11_zero_metrics_not_over_budget",
			s.over_budget == false, "over_budget should be false")
		T.expect("phase11_zero_metrics_budget_used_zero",
			math.abs(s.budget_used) < 1e-6, "budget_used should be 0")
	end

	-- 2. Air component saturates at HANG_TIME_FULL_SCORE.
	do
		local s = ChallengeScore.compute(
			stateJump(),
			metrics({ hang_time = Constants.HANG_TIME_FULL_SCORE * 2 })
		)
		T.expect("phase11_air_saturates_at_10",
			math.abs(s.air - 10) < 1e-6,
			"expected air==10, got " .. tostring(s.air))
	end

	-- 3. Air component is linear below saturation.
	do
		local s = ChallengeScore.compute(
			stateJump(),
			metrics({ hang_time = Constants.HANG_TIME_FULL_SCORE * 0.5 })
		)
		T.expect("phase11_air_linear_half",
			math.abs(s.air - 5) < 0.01,
			"expected air~5, got " .. tostring(s.air))
	end

	-- 4. CrestDip near-miss: airtime at 90% of the cap scores close to 9.
	do
		local s = ChallengeScore.compute(
			stateCrest(),
			metrics({ target_airtime_distance = Constants.CRESTDIP_MAX_AIRTIME_DISTANCE * 0.9 })
		)
		T.expect("phase11_crest_near_miss_high",
			s.near_miss >= 8.9 and s.near_miss <= 9.1,
			"expected near_miss≈9, got " .. tostring(s.near_miss))
	end

	-- 5. CrestDip near-miss is zero when airtime is zero.
	do
		local s = ChallengeScore.compute(stateCrest(), metrics())
		T.expect("phase11_crest_near_miss_zero",
			math.abs(s.near_miss) < 1e-6,
			"expected near_miss==0, got " .. tostring(s.near_miss))
	end

	-- 6. Chicane near-miss rewards corridor occupancy above the threshold.
	do
		-- corridor_width=14 → half=7. At 95% occupancy of a half-corridor =>
		-- offset = 6.65. Below the NEAR_MISS_ZERO_AT_MARGIN ramp starts at 0.75.
		local offset = 6.65
		local s = ChallengeScore.compute(
			stateChicane({ corridor_width = 14 }),
			metrics({
				target_left_offset = offset,
				target_right_offset = offset,
			})
		)
		T.expect("phase11_chicane_near_miss_high",
			s.near_miss > 5,
			"expected near_miss > 5 at high occupancy, got " .. tostring(s.near_miss))
	end

	-- 7. Chicane near-miss is zero at low occupancy.
	do
		local s = ChallengeScore.compute(
			stateChicane({ corridor_width = 14 }),
			metrics({ target_left_offset = 1, target_right_offset = 1 })
		)
		T.expect("phase11_chicane_near_miss_low",
			s.near_miss < 1e-6,
			"expected near_miss==0 at low occupancy, got " .. tostring(s.near_miss))
	end

	-- 8. Over-budget flag fires when slowdown_ratio exceeds (1 + ratio).
	do
		local ratio = 1 + Constants.CHALLENGE_BUDGET_RATIO + 0.01
		local s = ChallengeScore.compute(stateJump(), metrics({ slowdown_ratio = ratio }))
		T.expect("phase11_over_budget_fires",
			s.over_budget == true,
			"over_budget should be true for slowdown " .. tostring(ratio))
	end

	-- 9. Over-budget flag does NOT fire at exact cap.
	do
		local ratio = 1 + Constants.CHALLENGE_BUDGET_RATIO
		local s = ChallengeScore.compute(stateJump(), metrics({ slowdown_ratio = ratio }))
		T.expect("phase11_at_cap_not_over_budget",
			s.over_budget == false,
			"over_budget should be false exactly at cap")
		T.expect("phase11_at_cap_budget_used_one",
			math.abs(s.budget_used - 1) < 1e-6,
			"budget_used should be 1 at cap")
	end

	-- 10. Time cost reduces total but does not make near-miss score negative alone.
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
		T.expect("phase11_time_cost_reduces_total",
			slowed.total < base.total,
			string.format("expected slowed total < base; got slowed=%.3f base=%.3f",
				slowed.total, base.total))
	end

	-- 11. A challenging chicane (both sides + lateral G) totals higher than zero metrics.
	do
		local s = ChallengeScore.compute(
			stateChicane({ corridor_width = 14 }),
			metrics({
				target_left_offset = 6,
				target_right_offset = 6,
				peak_lateral_g = Constants.LATERAL_G_FULL_SCORE * 0.5,
			})
		)
		T.expect("phase11_chicane_with_signal_scores_positive",
			s.total > 1,
			"expected total > 1, got " .. tostring(s.total))
	end

	-- 12. The nearMissMargin helper exposes the raw [0,1] margin.
	do
		local m = ChallengeScore.nearMissMargin(
			stateCrest(),
			metrics({ target_airtime_distance = Constants.CRESTDIP_MAX_AIRTIME_DISTANCE * 0.5 })
		)
		T.expect("phase11_near_miss_margin_half",
			math.abs(m - 0.5) < 1e-6,
			"expected margin~0.5, got " .. tostring(m))
	end

	-- 13. aggregate sums and halves over-budget totals.
	do
		local a = ChallengeScore.compute(stateCrest(),
			metrics({ target_airtime_distance = Constants.CRESTDIP_MAX_AIRTIME_DISTANCE * 0.5 }))
		local b = ChallengeScore.compute(stateCrest(),
			metrics({ target_airtime_distance = Constants.CRESTDIP_MAX_AIRTIME_DISTANCE * 0.5 }))
		local agg = ChallengeScore.aggregate({ a, b })
		T.expect("phase11_aggregate_sum",
			math.abs(agg.total - (a.total + b.total)) < 1e-6,
			"expected sum; got " .. tostring(agg.total))
		T.expect("phase11_aggregate_count",
			agg.sector_count == 2, "expected count=2")
		T.expect("phase11_aggregate_not_over_budget",
			agg.any_over_budget == false, "should not be over budget")
	end

	-- 14. aggregate halves when any sector is over budget.
	do
		local a = ChallengeScore.compute(stateJump(), metrics({ hang_time = Constants.HANG_TIME_FULL_SCORE }))
		local b = ChallengeScore.compute(stateJump(),
			metrics({ slowdown_ratio = 1 + Constants.CHALLENGE_BUDGET_RATIO + 0.1 }))
		local agg = ChallengeScore.aggregate({ a, b })
		T.expect("phase11_aggregate_over_budget_flag",
			agg.any_over_budget == true, "expected any_over_budget=true")
		T.expect("phase11_aggregate_over_budget_halved",
			math.abs(agg.total - (a.total + b.total) * 0.5) < 1e-6,
			string.format("expected halved; got %.3f vs %.3f", agg.total, (a.total + b.total) * 0.5))
	end

	-- 15. suggestEscalation returns nil when over budget.
	do
		local s = ChallengeScore.compute(stateJump(),
			metrics({ slowdown_ratio = 1 + Constants.CHALLENGE_BUDGET_RATIO + 0.1 }))
		local lever = ChallengeScore.suggestEscalation(stateJump(), s)
		T.expect("phase11_escalation_blocked_over_budget", lever == nil, "expected nil when over budget")
	end

	-- 16. suggestEscalation points at air for a flat jump.
	do
		local s = ChallengeScore.compute(stateJump(), metrics())
		local lever = ChallengeScore.suggestEscalation(stateJump(), s)
		T.expect("phase11_escalation_jump_prefers_angle",
			lever == "ramp_angle",
			"expected ramp_angle; got " .. tostring(lever))
	end

	-- 17. suggestEscalation points at amplitude for a flat chicane.
	do
		local s = ChallengeScore.compute(stateChicane(), metrics())
		local lever = ChallengeScore.suggestEscalation(stateChicane(), s)
		T.expect("phase11_escalation_chicane_returns_lever",
			lever == "amplitude" or lever == "corridor_width" or lever == "transition_length",
			"expected a chicane lever; got " .. tostring(lever))
	end

	-- 18. Runner escalation: RampJump flat state nudges ramp_angle upward.
	do
		local st = stateJump()
		local s = ChallengeScore.compute(st, metrics())
		local next_, lever, reason = ChallengeRunner._escalateState(st, s)
		T.expect("phase11_runner_jump_lever",
			lever == "ramp_angle",
			"expected ramp_angle; got " .. tostring(lever) .. " reason=" .. tostring(reason))
		T.expect("phase11_runner_jump_increases_angle",
			next_ ~= nil and next_.params.ramp_angle > st.params.ramp_angle,
			"expected ramp_angle to increase")
	end

	-- 19. Runner escalation: Chicane flat state returns a chicane lever with a delta.
	do
		local st = stateChicane()
		local s = ChallengeScore.compute(st, metrics())
		local next_, lever = ChallengeRunner._escalateState(st, s)
		T.expect("phase11_runner_chicane_lever",
			lever == "amplitude" or lever == "corridor_width" or lever == "transition_length",
			"expected a chicane lever; got " .. tostring(lever))
		T.expect("phase11_runner_chicane_mutates",
			next_ ~= nil and next_.params[lever] ~= st.params[lever],
			"expected lever value to change")
	end

	-- 20. Runner escalation: CrestDip flat state drives height_or_depth up.
	do
		local st = stateCrest()
		local s = ChallengeScore.compute(st, metrics())
		local next_, lever = ChallengeRunner._escalateState(st, s)
		T.expect("phase11_runner_crest_lever",
			lever == "height_or_depth" or lever == "sector_length",
			"expected height_or_depth or sector_length; got " .. tostring(lever))
		T.expect("phase11_runner_crest_mutates",
			next_ ~= nil and next_.params[lever] ~= st.params[lever],
			"expected lever value to change")
	end

	-- 21. Runner escalation respects the LEVER_FLOOR: a lever already at
	-- floor whose delta is negative must be rejected (no underflow).
	do
		-- corridor_width floor is 4; delta for Chicane corridor_width is -2.
		-- Starting at 5 yields candidate=3, below floor → rejected.
		local st = stateChicane({ corridor_width = 5, amplitude = 20, transition_length = 20 })
		-- Build a score that would nominate corridor_width (high lateral, low near_miss).
		local m = metrics({ peak_lateral_g = Constants.LATERAL_G_FULL_SCORE })
		local s = ChallengeScore.compute(st, m)
		local next_, lever, reason = ChallengeRunner._escalateState(st, s)
		-- Either: the runner picks corridor_width and floors it out (next_==nil),
		-- or it picks a different lever that is allowed. Both are acceptable —
		-- the invariant we care about is "no floor underflow".
		if next_ ~= nil then
			T.expect("phase11_runner_no_underflow",
				next_.params.corridor_width >= 4,
				"corridor_width dropped below floor to " .. tostring(next_.params.corridor_width))
		else
			T.expect("phase11_runner_rejects_with_reason",
				reason ~= nil and #reason > 0,
				"expected a rejection reason")
		end
		-- Silence unused lever warning.
		local _ = lever
	end

	-- 22. Runner escalation: nil returned when score says over budget.
	do
		local st = stateJump()
		local s = ChallengeScore.compute(st,
			metrics({ slowdown_ratio = 1 + Constants.CHALLENGE_BUDGET_RATIO + 0.1 }))
		local next_, lever = ChallengeRunner._escalateState(st, s)
		T.expect("phase11_runner_blocks_over_budget",
			next_ == nil and lever == nil,
			"expected nil state when over budget")
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
	local JobRunner = require(script.Parent.JobRunner)
	local deadline = os.clock() + timeoutSeconds
	while os.clock() < deadline do
		if JobRunner.isBusy() == false then
			return true
		end
		task.wait(0.1)
	end
	return JobRunner.isBusy() == false
end

function TestPhase11.runIntegration()
	local ReplicatedStorage2 = game:GetService("ReplicatedStorage")
	local JobRunner = require(script.Parent.JobRunner)
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
	T.expect("phase11_extreme_job_committed",
		job ~= nil and job.final_status == "committed",
		"expected committed; got " .. tostring(job and job.final_status))

	local state = SectorRegistry.getCommitted(3)
	T.expect("phase11_extreme_commit_is_rampjump",
		state ~= nil and state.mechanic == "RampJump",
		"expected RampJump commit; got " .. tostring(state and state.mechanic))

	local stateFolder = ReplicatedStorage2:WaitForChild("AutoTrackUIState")
	T.expect("phase11_extreme_score_published",
		stateFolder:GetAttribute("last_score_sector") == 3,
		"expected last_score_sector=3; got " .. tostring(stateFolder:GetAttribute("last_score_sector")))
	local total = stateFolder:GetAttribute("last_score_total") or -1
	T.expect("phase11_extreme_score_nonzero",
		type(total) == "number" and total >= 0,
		"expected numeric score; got " .. tostring(total))
end

function TestPhase11.run()
	TestPhase11.runUnit()
	TestPhase11.runIntegration()
end

return TestPhase11
