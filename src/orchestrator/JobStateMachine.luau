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

function JobStateMachine.new(): typeof(JobStateMachine)
	return setmetatable({
		state = "Idle" :: State,
	}, JobStateMachine)
end

function JobStateMachine:transition(next: State)
	-- TODO: Phase 6 — add guard assertions for legal transitions
	self.state = next
end

function JobStateMachine:current(): State
	return self.state
end

return JobStateMachine
