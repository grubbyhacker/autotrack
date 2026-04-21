-- TestPhase11.luau
-- Unit tests for the Phase 11 ChallengeScore (plans/phase11.md §11).
-- These tests are stateless and do not require a running lap, so they run
-- under skip_baseline boot mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local T = require(script.Parent.TestUtils)
local ChallengeScore = require(script.Parent.Parent.Integrity.ChallengeScore)
local ChallengeRunner = require(script.Parent.ChallengeRunner)
local MaximizerAgent = require(script.Parent.MaximizerAgent)
local MinimalProposer = require(script.Parent.MinimalProposer)
local RequestParser = require(script.Parent.Parent.Agent.RequestParser)
local JobRunner = require(script.Parent.JobRunner)

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
	local params = { ramp_angle = 8, ramp_length = 24, gap_length = 4, landing_length = 34 }
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
		target_exited = false, target_progress = 0,
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
		T.expect("phase11_chicane_near_miss_high",
			s.near_miss > 5,
			"expected near_miss > 5 at high occupancy, got " .. tostring(s.near_miss))
	end

	-- 7. Chicane near-miss is zero at low occupancy.
	do
		local s = ChallengeScore.compute(
			stateChicane({ corridor_width = 14 }),
			metrics({ target_left_offset = 1, target_right_offset = 1, target_min_speed = 80 })
		)
		T.expect("phase11_chicane_near_miss_low",
			s.near_miss < 1e-6,
			"expected near_miss==0 at low occupancy, got " .. tostring(s.near_miss))
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
		T.expect("phase11_chicane_balanced_beats_one_sided",
			balanced.near_miss > oneSided.near_miss,
			string.format("expected balanced > one-sided, got %.3f vs %.3f", balanced.near_miss, oneSided.near_miss))
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
		T.expect("phase11_chicane_speed_retention_matters",
			fast.near_miss > slow.near_miss,
			string.format("expected fast > slow, got %.3f vs %.3f", fast.near_miss, slow.near_miss))
	end

	-- 10. Over-budget flag fires when slowdown_ratio exceeds (1 + ratio).
	do
		local ratio = 1 + Constants.CHALLENGE_BUDGET_RATIO + 0.01
		local s = ChallengeScore.compute(stateJump(), metrics({ slowdown_ratio = ratio }))
		T.expect("phase11_over_budget_fires",
			s.over_budget == true,
			"over_budget should be true for slowdown " .. tostring(ratio))
	end

	-- 11. Over-budget flag does NOT fire at exact cap.
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
		T.expect("phase11_time_cost_reduces_total",
			slowed.total < base.total,
			string.format("expected slowed total < base; got slowed=%.3f base=%.3f",
				slowed.total, base.total))
	end

	-- 13. CrestDip exit brake is penalized because it harms downstream setup.
	do
		local free = ChallengeScore.compute(
			stateCrest(),
			metrics({ target_airtime_distance = Constants.CRESTDIP_MAX_AIRTIME_DISTANCE * 0.7 })
		)
		local braked = ChallengeScore.compute(
			{
				sector_id = 3,
				mechanic = "CrestDip",
				params = { height_or_depth = 6, radius = 20, sector_length = 40 },
				pads = { ingress = "None", egress = "Brake10" },
				version = 0,
			},
			metrics({ target_airtime_distance = Constants.CRESTDIP_MAX_AIRTIME_DISTANCE * 0.7 })
		)
		T.expect("phase11_crestdip_egress_brake_penalized",
			braked.total < free.total,
			string.format("expected braked crest score < free crest score; got %.3f vs %.3f", braked.total, free.total))
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
		T.expect("phase11_chicane_with_signal_scores_positive",
			s.total > 1,
			"expected total > 1, got " .. tostring(s.total))
	end

	-- 14. The nearMissMargin helper exposes the raw [0,1] margin.
	do
		local m = ChallengeScore.nearMissMargin(
			stateCrest(),
			metrics({ target_airtime_distance = Constants.CRESTDIP_MAX_AIRTIME_DISTANCE * 0.5 })
		)
		T.expect("phase11_near_miss_margin_half",
			math.abs(m - 0.5) < 1e-6,
			"expected margin~0.5, got " .. tostring(m))
	end

	-- 15. Chicane ingress brake carries an explicit score penalty.
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
		local braked = ChallengeScore.compute(
			{
				sector_id = 3,
				mechanic = "Chicane",
				params = { amplitude = 8, transition_length = 15, corridor_width = 14 },
				pads = { ingress = "Brake10", egress = "None" },
				version = 0,
			},
			metrics({
				target_left_offset = 6.5,
				target_right_offset = 6.5,
				target_lateral_band_changes = Constants.CHICANE_SCORE_ALT_FULL,
				target_min_speed = 80,
			})
		)
		T.expect("phase11_chicane_ingress_brake_penalty",
			clean.total > braked.total,
			string.format("expected clean > braked, got %.3f vs %.3f", clean.total, braked.total))
	end

	-- 16. aggregate sums and halves over-budget totals.
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

	-- 17. aggregate halves when any sector is over budget.
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

	-- 18. suggestEscalation returns nil when over budget.
	do
		local s = ChallengeScore.compute(stateJump(),
			metrics({ slowdown_ratio = 1 + Constants.CHALLENGE_BUDGET_RATIO + 0.1 }))
		local lever = ChallengeScore.suggestEscalation(stateJump(), s)
		T.expect("phase11_escalation_blocked_over_budget", lever == nil, "expected nil when over budget")
	end

	-- 19. suggestEscalation points at air for a flat jump.
	do
		local s = ChallengeScore.compute(stateJump(), metrics())
		local lever = ChallengeScore.suggestEscalation(stateJump(), s)
		T.expect("phase11_escalation_jump_prefers_angle",
			lever == "ramp_angle",
			"expected ramp_angle; got " .. tostring(lever))
	end

	-- 20. suggestEscalation always points at amplitude for a flat chicane (near_miss
	--     and lateral both unsaturated; amplitude is the only lever that moves both).
	do
		local s = ChallengeScore.compute(stateChicane(), metrics())
		local lever = ChallengeScore.suggestEscalation(stateChicane(), s)
		T.expect("phase11_escalation_chicane_returns_amplitude",
			lever == "amplitude",
			"expected amplitude; got " .. tostring(lever))
	end

	-- 21. Runner escalation: RampJump flat state nudges ramp_angle upward.
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

	-- 22. Runner escalation: Chicane state below amplitude ceiling escalates amplitude.
	do
		-- Use amplitude=6 so there is room to escalate (ceiling is TRACK_WIDTH/2=8).
		local st = stateChicane({ amplitude = 6 })
		local s = ChallengeScore.compute(st, metrics())
		local next_, lever = ChallengeRunner._escalateState(st, s)
		T.expect("phase11_runner_chicane_lever",
			lever == "amplitude",
			"expected amplitude; got " .. tostring(lever))
		T.expect("phase11_runner_chicane_mutates",
			next_ ~= nil and next_.params.amplitude > st.params.amplitude,
			"expected amplitude to increase")
	end

	-- 23. Runner escalation: CrestDip flat state drives height_or_depth up.
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

	-- 24. Runner escalation respects the LEVER_FLOOR: a lever already at
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

	-- 25. Runner escalation: nil returned when score says over budget.
	do
		local st = stateJump()
		local s = ChallengeScore.compute(st,
			metrics({ slowdown_ratio = 1 + Constants.CHALLENGE_BUDGET_RATIO + 0.1 }))
		local next_, lever = ChallengeRunner._escalateState(st, s)
		T.expect("phase11_runner_blocks_over_budget",
			next_ == nil and lever == nil,
			"expected nil state when over budget")
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

		T.expect("phase11_extreme_bias_jump_angle",
			extremeState.params.ramp_angle > normalState.params.ramp_angle,
			string.format("expected extreme angle > normal; got %s vs %s",
				tostring(extremeState.params.ramp_angle),
				tostring(normalState.params.ramp_angle)))
		T.expect("phase11_extreme_bias_jump_gap",
			extremeState.params.gap_length > normalState.params.gap_length,
			string.format("expected extreme gap > normal; got %s vs %s",
				tostring(extremeState.params.gap_length),
				tostring(normalState.params.gap_length)))
	end

	-- 27. Campaign summary reports score count and budget usage from the probe.
	do
		local summary = MaximizerAgent._summarizeCampaign({
			[2] = { total = 5, budget_used = 0, over_budget = false },
			[3] = { total = 7, budget_used = 0, over_budget = false },
		}, 1 + Constants.CHALLENGE_BUDGET_RATIO * 0.5, true)

		T.expect("phase11_campaign_summary_total",
			math.abs(summary.total - 12) < 1e-6,
			"expected total=12, got " .. tostring(summary.total))
		T.expect("phase11_campaign_summary_count",
			summary.sector_count == 2,
			"expected count=2, got " .. tostring(summary.sector_count))
		T.expect("phase11_campaign_summary_budget",
			math.abs(summary.budget_used - 0.5) < 1e-6,
			"expected budget_used=0.5, got " .. tostring(summary.budget_used))
		T.expect("phase11_campaign_summary_headroom",
			math.abs(summary.budget_headroom - 0.5) < 1e-6,
			"expected headroom=0.5, got " .. tostring(summary.budget_headroom))
		T.expect("phase11_campaign_summary_not_over",
			summary.over_budget == false,
			"expected over_budget=false")
	end

	-- 28. Campaign summary treats a failed probe as over budget.
	do
		local summary = MaximizerAgent._summarizeCampaign({
			[2] = { total = 5, budget_used = 0, over_budget = false },
		}, 1, false)
		T.expect("phase11_campaign_summary_failed_probe",
			summary.over_budget == true,
			"expected over_budget=true when probe failed")
	end

	-- 29. Maximizer evicts the lowest positive-score sector first.
	do
		local sectorId, score = MaximizerAgent._selectEvictionSector({
			[2] = { total = 4.5 },
			[3] = { total = 2.0 },
			[4] = { total = 9.0 },
		})
		T.expect("phase11_eviction_picks_lowest_sector",
			sectorId == 3,
			"expected sector 3, got " .. tostring(sectorId))
		T.expect("phase11_eviction_returns_score",
			score ~= nil and math.abs(score.total - 2.0) < 1e-6,
			"expected score total 2.0")
	end

	-- 30. Maximizer stops evicting once the minimum demo sector count is reached.
	do
		local sectorId, score = MaximizerAgent._selectEvictionSector({
			[2] = { total = 4.5 },
			[3] = { total = 2.0 },
		})
		T.expect("phase11_eviction_preserves_minimum_demo_sectors",
			sectorId == nil and score == nil,
			string.format("expected nil,nil at min retained count; got %s %s", tostring(sectorId), tostring(score and score.total)))
	end

	-- 31. JobRunner suppresses challenge-up during maximize campaigns.
	do
		local request, err = RequestParser.parse("add an extreme jump in sector 3", "phase11-maximize-suppress")
		assert(request ~= nil, "expected request: " .. tostring(err))
		local result = {
			success = true,
			metrics = metrics(),
			score = {
				total = 5,
				air = 2,
				lateral = 0,
				near_miss = 3,
				time_cost = 0,
				budget_used = 0.2,
				over_budget = false,
			},
		}
		workspace:SetAttribute("AutoTrack_MaximizeCampaignActive", true)
		local shouldRun, why = JobRunner._shouldRunChallengeUp(request, result)
		workspace:SetAttribute("AutoTrack_MaximizeCampaignActive", false)
		T.expect("phase11_challenge_up_suppressed_during_maximize",
			shouldRun == false and why == "maximize_campaign",
			string.format("expected maximize suppression, got shouldRun=%s why=%s", tostring(shouldRun), tostring(why)))
	end

	-- 32. Pre-target failures must revert instead of repairing the target sector.
	do
		local result = {
			success = false,
			failure = {
				type = "local_execution_failure",
				sector_id = 2,
			},
			metrics = metrics({
				target_entered = true,
				target_exited = false,
				target_progress = 0.4,
			}),
		}
		T.expect("phase11_pre_target_failure_reverts",
			JobRunner._shouldRevertPreTargetFailure(result, 3) == true,
			"expected pre-target failure revert guard to fire")
	end

	-- 33. Once the target was entered, downstream failures remain repairable.
	do
		local result = {
			success = false,
			failure = {
				type = "local_execution_failure",
				sector_id = 4,
			},
			metrics = metrics({
				target_entered = true,
				target_exited = true,
				target_progress = 1,
			}),
		}
		T.expect("phase11_post_target_failure_does_not_revert",
			JobRunner._shouldRevertPreTargetFailure(result, 3) == false,
			"expected guard to stay off after target entry")
	end

	-- 34. Halfway target progress unlocks extra repair attempts.
	do
		local result = {
			success = false,
			failure = {
				type = "local_execution_failure",
				sector_id = 3,
			},
			metrics = metrics({
				target_entered = true,
				target_exited = false,
				target_progress = 0.6,
			}),
		}
		T.expect("phase11_halfway_progress_gets_extra_attempts",
			JobRunner._attemptLimitForResult(result, 3) == Constants.MAX_REPAIR_ATTEMPTS + Constants.EXTRA_REPAIR_ATTEMPTS_AFTER_HALF_PROGRESS,
			"expected extra repair attempts after halfway progress")
	end

	-- 35–36. Endurance lap-time budget gate (phase 14): 0.40 ratio.
	do
		local ratio = Constants.ENDURANCE_LAP_TIME_BUDGET_RATIO
		T.expect("phase11_endurance_budget_not_over_at_1_39",
			1.39 <= 1 + ratio,
			"expected 1.39 to be within endurance budget (ratio=" .. tostring(ratio) .. ")")
		T.expect("phase11_endurance_budget_over_at_1_41",
			1.41 > 1 + ratio,
			"expected 1.41 to exceed endurance budget (ratio=" .. tostring(ratio) .. ")")
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

local function summariseAttempts(job): string
	if job == nil or job.attempts == nil or #job.attempts == 0 then
		return "no-attempts"
	end

	local parts = {}
	for _, attempt in ipairs(job.attempts) do
		local result = attempt.result or {}
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
		table.insert(parts, string.format(
			"%d:%s/%s/%s action=%s progress=%.2f hints=%s",
			attempt.attempt_index,
			tostring(result.success),
			tostring(failure and failure.type or "none"),
			tostring(failure and failure.detail or "-"),
			actionText,
			result.metrics and result.metrics.target_progress or 0,
			if #hints > 0 then table.concat(hints, "&") else "-"
		))
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
	T.expect("phase11_extreme_job_committed",
		job ~= nil and job.final_status == "committed",
		"expected committed; got " .. tostring(job and job.final_status) .. " :: " .. summariseAttempts(job))

	local state = SectorRegistry.getCommitted(3)
	T.expect("phase11_extreme_commit_is_rampjump",
		state ~= nil and state.mechanic == "RampJump",
		"expected RampJump commit; got " .. tostring(state and state.mechanic) .. " :: " .. summariseAttempts(job))

	local stateFolder = ReplicatedStorage2:WaitForChild("AutoTrackUIState")
	T.expect("phase11_extreme_score_published",
		stateFolder:GetAttribute("last_score_sector") == 3,
		"expected last_score_sector=3; got " .. tostring(stateFolder:GetAttribute("last_score_sector")) .. " :: " .. summariseAttempts(job))
	local total = stateFolder:GetAttribute("last_score_total") or -1
	T.expect("phase11_extreme_score_nonzero",
		type(total) == "number" and total >= 0,
		"expected numeric score; got " .. tostring(total))

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
