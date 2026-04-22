-- ChallengeRunner.luau
-- Phase 11b Stage B — after an initial integrity commit, attempt to escalate
-- the committed SectorState so the score goes up while integrity still passes
-- and the slowdown budget is not exceeded.
--
-- Stateless. Does not mutate SectorRegistry. The caller (JobRunner) decides
-- when to promote the escalated state to a new commit.
--
-- plans/phase11.md §3.3, §10

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local ChallengeScore = require(script.Parent.Parent.Integrity.ChallengeScore)
local AttemptRunner = require(script.Parent.AttemptRunner)

type SectorState = Types.SectorState
type RunResult = Types.RunResult

local ChallengeRunner = {}

-- Sign and magnitude to apply when a lever is chosen for escalation. Pushes in
-- the direction that is expected to raise the score for its mechanic. Clamped
-- downstream. Conservative deltas keep each challenge-up step small so a
-- single over-step does not torpedo integrity.
local ESCALATION_DELTA = {
	RampJump = {
		ramp_angle = 3,
		gap_length = 2,
		ramp_length = 2,
		landing_length = -2,
	},
	Chicane = {
		amplitude = 2,
		transition_length = -3,
		corridor_width = -2,
	},
	CrestDip = {
		height_or_depth = 2,
		sector_length = -4,
		radius = 0,   -- cosmetic; do not bother
	},
}

-- Per-lever upper bounds. Amplitude must stay within the physical track half-width
-- so the chicane centerline never exits the sector.
local LEVER_CEILING = {
	amplitude = Constants.TRACK_WIDTH * 0.5,
	transition_length = LevelMappings.LEVER_BOUNDS.Chicane.transition_length.max,
	corridor_width = math.min(LevelMappings.LEVER_BOUNDS.Chicane.corridor_width.max, Constants.TRACK_WIDTH),
}

-- Per-lever clamps. Values below the floor are rejected so we do not ask for
-- physically impossible geometry. Mirrors existing MinimalProposer floors.
local LEVER_FLOOR = {
	ramp_angle = 5,
	ramp_length = 4,
	gap_length = 2,
	landing_length = 4,
	amplitude = 1,
	transition_length = LevelMappings.LEVER_BOUNDS.Chicane.transition_length.min,
	corridor_width = LevelMappings.LEVER_BOUNDS.Chicane.corridor_width.min,
	height_or_depth = 2,
	sector_length = 16,
	radius = 1,
}

local function cloneState(state: SectorState): SectorState
	local params = {}
	for key, value in pairs(state.params) do params[key] = value end
	return {
		sector_id = state.sector_id,
		mechanic = state.mechanic,
		params = params,
		pads = { ingress = state.pads.ingress, egress = state.pads.egress },
		version = state.version,
	}
end

-- Pick the escalation lever, apply the mapped delta, and return a fresh state
-- ready to hand to AttemptRunner. Returns nil when no escalation is possible
-- (no suggestion, no delta table entry, or the resulting value would drop
-- below the floor).
local function escalateState(state: SectorState, score: Types.ChallengeScore): (SectorState?, string?, string?)
	local lever, reason = ChallengeScore.suggestEscalation(state, score)
	if lever == nil then return nil, nil, reason end

	local mechanic = state.mechanic
	if not mechanic then return nil, nil, "no mechanic" end
	local deltaTable = ESCALATION_DELTA[mechanic]
	if not deltaTable then return nil, nil, "no delta table" end

	local delta = deltaTable[lever]
	if delta == nil or delta == 0 then return nil, nil, "no delta for " .. lever end

	local current = state.params[lever]
	if type(current) ~= "number" then return nil, nil, "lever not numeric" end

	local candidate = current + delta
	local ceiling = LEVER_CEILING[lever]
	if ceiling and candidate > ceiling then
		candidate = ceiling
	end
	local floor = LEVER_FLOOR[lever] or 1
	if candidate < floor then
		return nil, nil, string.format("%s=%d would underflow floor %d", lever, candidate, floor)
	end
	if candidate == current then
		return nil, nil, string.format("%s already at ceiling %s", lever, tostring(ceiling))
	end

	local next_ = cloneState(state)
	next_.params[lever] = candidate
	return next_, lever, nil
end

-- Stage B escalation loop. Returns the best state/result observed plus the
-- number of rounds taken (including the one that failed to improve).
--
-- args: {
--   baseState      : SectorState,     -- the already-committed state
--   baseResult     : RunResult,       -- the RunResult that committed it (score populated)
--   targetSectorId : number,
--   targetSector   : SectorMeta,
--   sectors        : { SectorMeta },
--   car            : BasePart,
--   canonicalStart : CFrame,
--   onSectorChange : ((number, boolean) -> ())?,
--   onRound        : ((round, attempt, improved) -> ())?,  -- UI callback
-- }
function ChallengeRunner.runUp(args): (SectorState, RunResult, number)
	local bestState = cloneState(args.baseState)
	local bestResult = args.baseResult
	local rounds = 0

	if bestResult == nil or bestResult.score == nil then
		return bestState, bestResult, 0
	end
	if bestResult.score.over_budget then
		if args.onRound then args.onRound(0, nil, false, "over budget; no escalation") end
		return bestState, bestResult, 0
	end

	for round = 1, Constants.CHALLENGE_UP_ROUNDS do
		rounds = round
		local candidateState, lever, skipReason = escalateState(bestState, bestResult.score)
		if not candidateState then
			if args.onRound then args.onRound(round, nil, false, skipReason or "no candidate") end
			break
		end

		local attempt = {
			state = candidateState,
			lever = lever,
			from = bestState.params[lever],
			to = candidateState.params[lever],
		}

		local result, _hints, updatedState = AttemptRunner.run({
			workingState = candidateState,
			action = nil,
			targetSectorId = args.targetSectorId,
			entryFrame = args.targetSector.entry,
			exitFrame = args.targetSector.exit,
			sectors = args.sectors,
			car = args.car,
			canonicalStart = args.canonicalStart,
			onSectorChange = args.onSectorChange,
		})

		if not result.success then
			if args.onRound then args.onRound(round, attempt, false, "integrity regressed") end
			break
		end
		if result.score == nil then
			if args.onRound then args.onRound(round, attempt, false, "no score on result") end
			break
		end
		if result.score.over_budget then
			if args.onRound then args.onRound(round, attempt, false, "over budget") end
			break
		end
		if result.score.total < bestResult.score.total + Constants.MIN_ESCALATION_DELTA then
			if args.onRound then args.onRound(round, attempt, false, "insufficient improvement") end
			break
		end

		bestState = cloneState(updatedState)
		bestResult = result
		if args.onRound then args.onRound(round, attempt, true, nil) end
	end

	return bestState, bestResult, rounds
end

-- Test hook: exposes the private escalateState so unit tests can poke at the
-- lever/sign/floor selection without a lap.
function ChallengeRunner._escalateState(state: SectorState, score: Types.ChallengeScore)
	return escalateState(state, score)
end

return ChallengeRunner
