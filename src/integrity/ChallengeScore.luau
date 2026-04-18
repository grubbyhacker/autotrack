-- ChallengeScore.luau
-- Pure-function fitness signal for a successfully verified sector.
-- prd_plan.md extension; plans/phase11.md §3.1, §10
--
-- Purpose:
--   Turn the satisfice-the-gate agent into a maximise-under-budget agent by
--   exposing a scalar score for each committed sector plus a hard track-wide
--   budget flag. No side effects. No workspace access. No RNG.
--
-- Inputs:
--   state   : SectorState        -- the committed (or candidate) sector state
--   metrics : RunMetrics         -- finalised metrics from MetricCollector
--
-- Returns:
--   ChallengeScore               -- { total, air, lateral, near_miss,
--                                     time_cost, budget_used, over_budget }
--
-- The score is computed even for mechanics that did not exercise a given
-- component (e.g. Chicane has no air component) — the unused components just
-- read as 0. This keeps the shape consistent so UI code does not branch on
-- mechanic.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

type SectorState = Types.SectorState
type RunMetrics = Types.RunMetrics

local ChallengeScore = {}

local function clamp01(x: number): number
	if x < 0 then return 0 end
	if x > 1 then return 1 end
	return x
end

local function safeDiv(num: number, denom: number): number
	if denom <= 0 then return 0 end
	return num / denom
end

-- Air component: hang time saturates at HANG_TIME_FULL_SCORE seconds.
-- Falls back to target_air_distance / HANG_TIME_FULL_SCORE in distance-units
-- when hang_time is unavailable (pre-11a MetricCollector).
local function airComponent(metrics: RunMetrics): number
	local hang = metrics.hang_time or 0
	if hang > 0 then
		return clamp01(safeDiv(hang, Constants.HANG_TIME_FULL_SCORE)) * 10
	end
	-- Fallback: approximate hang from target airtime distance assuming baseline
	-- forward speed. air_distance / BASELINE_SPEED ≈ time-at-speed.
	local airDist = metrics.target_airtime_distance or metrics.airtime_distance or 0
	local approxHang = safeDiv(airDist, Constants.BASELINE_SPEED)
	return clamp01(safeDiv(approxHang, Constants.HANG_TIME_FULL_SCORE)) * 10
end

-- Lateral component: estimate of peak lateral g from offsets + entry speed.
-- Preferred source: metrics.peak_lateral_g (11a MetricCollector field).
-- Fallback: approximate from lateral offset / transition budget and entry speed.
local function lateralComponent(state: SectorState, metrics: RunMetrics): number
	local peakG = metrics.peak_lateral_g or 0
	if peakG > 0 then
		return clamp01(safeDiv(peakG, Constants.LATERAL_G_FULL_SCORE)) * 10
	end
	if state.mechanic ~= "Chicane" then
		return 0
	end
	local leftOffset = metrics.target_left_offset or 0
	local rightOffset = metrics.target_right_offset or 0
	local swing = leftOffset + rightOffset
	local transition = state.params.transition_length or 1
	-- Coarse lateral acceleration proxy: (2 * swing) / transition² * speed²
	local entrySpeed = metrics.entry_speed
	if entrySpeed <= 0 then entrySpeed = Constants.BASELINE_SPEED end
	local approxG = (2 * swing * entrySpeed * entrySpeed) / math.max(1, transition * transition)
	return clamp01(safeDiv(approxG, Constants.LATERAL_G_FULL_SCORE)) * 10
end

-- Per-mechanic near-miss margin to the integrity threshold. Returns [0, 1].
-- Higher means closer to the wall / cap / reacquire limit.
local function nearMissMargin(state: SectorState, metrics: RunMetrics): number
	local mechanic = state.mechanic
	local zeroAt = Constants.NEAR_MISS_ZERO_AT_MARGIN

	if mechanic == "RampJump" then
		-- For now we only have reacquired (bool). True reacquire distance
		-- telemetry is a separate follow-up. Until then, airborne-but-reacquired
		-- scores 0.7; long-airtime scores 1.0 if airborne at sector exit.
		local air = metrics.target_air_distance or 0
		local maxAir = Constants.RAMPJUMP_REACQUIRE_MAX
		if maxAir <= 0 then return 0 end
		-- Tuning note: once a RAMPJUMP_REACQUIRE_MARGIN field lands in metrics,
		-- swap this for the true margin computation.
		local approxMargin = clamp01(safeDiv(air, maxAir))
		return approxMargin * 1.0

	elseif mechanic == "CrestDip" then
		local airtime = metrics.target_airtime_distance or 0
		local cap = Constants.CRESTDIP_MAX_AIRTIME_DISTANCE
		if cap <= 0 then return 0 end
		local ratio = safeDiv(airtime, cap)
		-- Reward a ratio that is close to 1 but not over. The integrity check
		-- already rejects > 1; clamp here defensively.
		return clamp01(ratio)

	elseif mechanic == "Chicane" then
		local leftOffset = metrics.target_left_offset or 0
		local rightOffset = metrics.target_right_offset or 0
		local maxOffset = math.max(leftOffset, rightOffset)
		local corridorWidth = state.params.corridor_width or Constants.TRACK_WIDTH
		local corridorHalf = corridorWidth * 0.5
		if corridorHalf <= 0 then return 0 end
		local occupancy = safeDiv(maxOffset, corridorHalf)
		-- Ramp: below zeroAt fraction → 0, at 1.0 → 1.0 (wall contact).
		return clamp01(safeDiv(occupancy - zeroAt, 1 - zeroAt))
	end

	return 0
end

local function nearMissComponent(state: SectorState, metrics: RunMetrics): number
	return nearMissMargin(state, metrics) * 10
end

-- Time cost: how much of the slowdown budget this sector consumed (normalised
-- to the full budget). Note: slowdown_ratio is lap-global today, so this is
-- effectively a track-level signal applied uniformly to each sector. True
-- per-sector time cost is follow-up work (phase 11b).
local function timeCostComponent(metrics: RunMetrics): number
	local slowdown = metrics.slowdown_ratio or 1
	local excess = slowdown - 1
	return clamp01(safeDiv(excess, Constants.CHALLENGE_BUDGET_RATIO)) * 10
end

function ChallengeScore.compute(state: SectorState, metrics: RunMetrics)
	local air = airComponent(metrics)
	local lateral = lateralComponent(state, metrics)
	local nearMiss = nearMissComponent(state, metrics)
	local timeCost = timeCostComponent(metrics)

	local total = Constants.SCORE_W_AIR * air
		+ Constants.SCORE_W_LATERAL * lateral
		+ Constants.SCORE_W_NEAR_MISS * nearMiss
		- Constants.SCORE_W_TIME * timeCost

	local slowdown = metrics.slowdown_ratio or 1
	local budgetUsed = clamp01(safeDiv(slowdown - 1, Constants.CHALLENGE_BUDGET_RATIO))
	local overBudget = slowdown > (1 + Constants.CHALLENGE_BUDGET_RATIO)

	return {
		total = total,
		air = air,
		lateral = lateral,
		near_miss = nearMiss,
		time_cost = timeCost,
		budget_used = budgetUsed,
		over_budget = overBudget,
	}
end

-- Helper for tests: the raw [0,1] near-miss margin without the ×10 scaling.
function ChallengeScore.nearMissMargin(state: SectorState, metrics: RunMetrics): number
	return nearMissMargin(state, metrics)
end

return ChallengeScore
