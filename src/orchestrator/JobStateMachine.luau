-- JobStateMachine.luau
-- State machine for one CI job.
-- prd_plan.md §7, Phase 6
--
-- States:
--   Idle → ParseRequest → RejectRequest
--                       → AcquireTrack → GenerateInitialProposal
--                                      → ApplyWorkingSector
--                                      → RunVerification
--                                      → EvaluateResult → Commit
--                                                       → AnalyzeFailure
--                                                       → ApplyRepair → RunVerification (loop)
--                                                       → Revert

export type State =
	"Idle"
	| "ParseRequest"
	| "RejectRequest"
	| "AcquireTrack"
	| "GenerateInitialProposal"
	| "ApplyWorkingSector"
	| "RunVerification"
	| "EvaluateResult"
	| "AnalyzeFailure"
	| "ApplyRepair"
	| "Commit"
	| "Revert"

local JobStateMachine = {}
JobStateMachine.__index = JobStateMachine

export type JobStateMachine = typeof(setmetatable({} :: { state: State }, JobStateMachine))

local LEGAL_TRANSITIONS = {
	Idle = {
		ParseRequest = true,
	},
	ParseRequest = {
		RejectRequest = true,
		AcquireTrack = true,
	},
	RejectRequest = {
		Idle = true,
	},
	AcquireTrack = {
		RejectRequest = true,
		GenerateInitialProposal = true,
	},
	GenerateInitialProposal = {
		ApplyWorkingSector = true,
		RejectRequest = true,
	},
	ApplyWorkingSector = {
		RunVerification = true,
	},
	RunVerification = {
		EvaluateResult = true,
	},
	EvaluateResult = {
		Commit = true,
		AnalyzeFailure = true,
	},
	AnalyzeFailure = {
		ApplyRepair = true,
		Revert = true,
	},
	ApplyRepair = {
		ApplyWorkingSector = true,
		Revert = true,
	},
	Commit = {
		Idle = true,
	},
	Revert = {
		Idle = true,
	},
}

function JobStateMachine.new(): JobStateMachine
	return setmetatable({
		state = "Idle" :: State,
	}, JobStateMachine)
end

function JobStateMachine:transition(next: State)
	local legal = LEGAL_TRANSITIONS[self.state]
	assert(legal and legal[next], string.format("illegal transition: %s -> %s", self.state, next))
	self.state = next
end

function JobStateMachine:current(): State
	return self.state
end

return JobStateMachine
