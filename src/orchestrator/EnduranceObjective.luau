--!strict

-- EnduranceObjective.luau
-- Shared scoring policy for phase-14.5 endurance orchestration decisions.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

type OrchestratorContext = Types.OrchestratorContext
type OrchestratorDecision = Types.OrchestratorDecision
type CandidateScore = Types.CandidateScore

local EnduranceObjective = {}

local REPEAT_SKIP_THRESHOLD = 3
local SUPPORTED_MECHANICS: { [string]: boolean } = {
	RampJump = true,
	Chicane = true,
	CrestDip = true,
}

local function clamp01(value: number): number
	return math.clamp(value, 0, 1)
end

local function normalizeHint(paramsHint: string?): string
	if type(paramsHint) ~= "string" then
		return ""
	end

	local words: { string } = {}
	local seen: { [string]: boolean } = {}
	for word in string.gmatch(string.lower(paramsHint), "[%w%-]+") do
		if #word >= 3 and not seen[word] then
			seen[word] = true
			table.insert(words, word)
		end
	end
	if #words == 0 then
		return ""
	end
	return table.concat(words, " ")
end

function EnduranceObjective.signature(decision: OrchestratorDecision): string
	if decision.action == "begin_loop" then
		return "begin_loop"
	end

	return string.format("s%d|%s|%s", decision.sector_id, decision.mechanic, normalizeHint(decision.params_hint))
end

local function sectorAttemptCount(context: OrchestratorContext, sectorId: number): number
	if context.sector_attempt_counts == nil then
		return 0
	end
	return context.sector_attempt_counts[sectorId] or 0
end

local function signatureCount(context: OrchestratorContext, signature: string): number
	if context.mechanic_repeat_pressure == nil then
		return 0
	end
	return context.mechanic_repeat_pressure[signature] or 0
end

local function attemptsForSector(context: OrchestratorContext, sectorId: number): (number, number)
	if context.attempt_history == nil then
		return 0, 0
	end

	local attempts = 0
	local failures = 0
	for _, attempt in ipairs(context.attempt_history) do
		if attempt.sector_id == sectorId then
			attempts += 1
			if attempt.outcome == "reverted" then
				failures += 1
			end
		end
	end

	return attempts, failures
end

local function attemptRepairLoad(context: OrchestratorContext, sectorId: number): number
	if context.attempt_history == nil then
		return 0
	end

	local complexity = 0
	for _, attempt in ipairs(context.attempt_history) do
		if attempt.sector_id == sectorId then
			complexity += attempt.repair_iterations or 0
		end
	end
	return complexity
end

local function mechanicHistoryStats(context: OrchestratorContext, mechanic: string): (number, number, number)
	if context.attempt_history == nil then
		return 0, 0, 0
	end

	local attempts = 0
	local commits = 0
	local committedScoreTotal = 0
	for _, attempt in ipairs(context.attempt_history) do
		if attempt.mechanic == mechanic then
			attempts += 1
			if attempt.outcome == "committed" then
				commits += 1
				if type(attempt.score) == "number" then
					committedScoreTotal += math.max(0, attempt.score)
				end
			end
		end
	end

	return attempts, commits, committedScoreTotal
end

local function realizedYield(context: OrchestratorContext, mechanic: string): number
	if not SUPPORTED_MECHANICS[mechanic] then
		return Constants.ENDURANCE_OBJECTIVE_REALIZED_YIELD_NEUTRAL
	end

	local attempts, commits, committedScoreTotal = mechanicHistoryStats(context, mechanic)
	if attempts == 0 then
		return Constants.ENDURANCE_OBJECTIVE_REALIZED_YIELD_NEUTRAL
	end

	local commitRate = commits / attempts
	local avgCommittedScore = if commits == 0 then 0 else committedScoreTotal / commits
	local committedScoreNorm =
		clamp01(avgCommittedScore / math.max(1, Constants.ENDURANCE_OBJECTIVE_COMMITTED_SCORE_FULL))
	return clamp01(commitRate * 0.65 + committedScoreNorm * 0.35)
end

local function explorationBonus(context: OrchestratorContext, mechanic: string): number
	if not SUPPORTED_MECHANICS[mechanic] then
		return 0
	end
	if context.attempt_history == nil or #context.attempt_history == 0 then
		return 0
	end

	local totalMechanicAttempts = 0
	local thisMechanicAttempts = 0
	for _, attempt in ipairs(context.attempt_history) do
		local attemptMechanic = attempt.mechanic
		if type(attemptMechanic) == "string" and SUPPORTED_MECHANICS[attemptMechanic] then
			totalMechanicAttempts += 1
			if attemptMechanic == mechanic then
				thisMechanicAttempts += 1
			end
		end
	end
	if totalMechanicAttempts == 0 then
		return 0
	end

	local targetShare = 1 / 3
	local actualShare = thisMechanicAttempts / totalMechanicAttempts
	return clamp01(math.max(0, targetShare - actualShare) / targetShare)
end

local function currentSectorScore(context: OrchestratorContext, sectorId: number): number
	local snapshot = context.sector_states and context.sector_states[sectorId]
	if snapshot == nil then
		return 0
	end
	return snapshot.score or 0
end

local function currentBudgetRisk(context: OrchestratorContext): number
	if context == nil or context.budget == nil then
		return 0
	end
	if context.budget.over_budget == true then
		return 0.9
	end
	return clamp01((context.budget.used - 0.78) * 2.2)
end

function EnduranceObjective.evaluateCandidate(
	context: OrchestratorContext,
	decision: OrchestratorDecision
): (CandidateScore, string)
	if decision == nil or decision.action == "begin_loop" then
		local score: CandidateScore = {
			base_score_gain = 0,
			track_sustainability = 0,
			novelty_bonus = 0,
			repeat_penalty = 0,
			budget_risk_penalty = 0,
			repair_complexity_penalty = 0,
			total = -math.huge,
			reliability_index = 0,
		}
		return score, "loop request cannot be compared in this evaluator"
	end

	local sectorId = decision.sector_id
	local snapshot = context.sector_states and context.sector_states[sectorId]
	local signature = EnduranceObjective.signature(decision)
	local repeatPressure = signatureCount(context, signature)

	local sectorScore = currentSectorScore(context, sectorId)
	local filled = snapshot ~= nil and snapshot.mechanic ~= nil
	local opennessBonus = if filled then 0.25 else 0.65
	local baseRaw = (72 - sectorScore) / 72
	if baseRaw < 0 then
		baseRaw = 0
	end
	local base_score_gain = clamp01(baseRaw + opennessBonus)

	local sectorAttempts, sectorFailures = attemptsForSector(context, sectorId)
	local repairLoad = attemptRepairLoad(context, sectorId)
	local repairRate = if sectorAttempts == 0 then 0 else sectorFailures / sectorAttempts
	local track_sustainability = clamp01(1 - (repairRate * 1.0) - (sectorAttempts * 0.04))

	local novelty_bonus = clamp01(1 - repeatPressure * 0.22)
	local repeat_penalty = clamp01(repeatPressure * 0.22)
	local budget_risk_penalty = currentBudgetRisk(context)
	local mechanicName = decision.mechanic
	local realized_yield = realizedYield(context, mechanicName)
	local exploration_bonus = explorationBonus(context, mechanicName)
	local repair_complexity_penalty = 0

	local reliability_index = clamp01(
		(base_score_gain * 0.3)
			+ (track_sustainability * 0.35)
			+ (novelty_bonus * 0.1)
			+ (realized_yield * 0.1)
			+ (1 - budget_risk_penalty) * 0.15
	)

	local total = base_score_gain * Constants.ENDURANCE_OBJECTIVE_WEIGHT_BASE_GAIN
		+ novelty_bonus * Constants.ENDURANCE_OBJECTIVE_WEIGHT_NOVELTY
		- repeat_penalty * Constants.ENDURANCE_OBJECTIVE_WEIGHT_REPEAT
		- budget_risk_penalty * Constants.ENDURANCE_OBJECTIVE_WEIGHT_BUDGET_RISK
		+ realized_yield * Constants.ENDURANCE_OBJECTIVE_WEIGHT_REALIZED_YIELD
		+ exploration_bonus * Constants.ENDURANCE_OBJECTIVE_WEIGHT_EXPLORATION

	local score: CandidateScore = {
		base_score_gain = base_score_gain,
		track_sustainability = track_sustainability,
		novelty_bonus = novelty_bonus,
		repeat_penalty = repeat_penalty,
		budget_risk_penalty = budget_risk_penalty,
		repair_complexity_penalty = repair_complexity_penalty,
		total = total,
		reliability_index = reliability_index,
	}

	local rationale = string.format(
		"sector=%d score=%.1f openness=%.2f repeat=%d failures=%d repair_steps=%d budget=%.2f yield=%.2f explore=%.2f",
		sectorId,
		sectorScore,
		opennessBonus,
		repeatPressure,
		sectorFailures,
		repairLoad,
		context.budget and context.budget.used or 0,
		realized_yield,
		exploration_bonus
	)

	return score, rationale
end

function EnduranceObjective.shouldAvoidRepeat(context: OrchestratorContext, decision: OrchestratorDecision): boolean
	if decision == nil or decision.action == "begin_loop" then
		return false
	end
	return signatureCount(context, EnduranceObjective.signature(decision)) >= REPEAT_SKIP_THRESHOLD
		or sectorAttemptCount(context, decision.sector_id) >= 4
end

function EnduranceObjective.threshold()
	return REPEAT_SKIP_THRESHOLD
end

return EnduranceObjective
