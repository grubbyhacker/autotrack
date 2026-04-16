-- JobRunner.luau
-- Top-level CI job runner.  Drives the full propose → verify → repair → commit/revert loop.
-- prd_plan.md §7, Phase 6
--
-- Entry point: JobRunner.submit(rawText)
-- There is exactly one global job lock — concurrent submissions are rejected immediately.

local Types = require(script.Parent.Parent.common.Types)
local Constants      = require(script.Parent.Parent.common.Constants)
local LevelMappings  = require(script.Parent.Parent.common.LevelMappings)
local RequestParser  = require(script.Parent.Parent.agent.RequestParser)
local LLMAdapter     = require(script.Parent.Parent.agent.LLMAdapter)
local SectorRegistry = require(script.Parent.Parent.track.SectorRegistry)
local SectorRollback = require(script.Parent.Parent.track.SectorRollback)
local AttemptRunner  = require(script.Parent.AttemptRunner)
local JobStateMachine = require(script.Parent.JobStateMachine)

type CIJob = Types.CIJob

local JobRunner = {}

local _busy = false

-- Submit a plain-text request.  Returns false + reason if rejected without running.
function JobRunner.submit(rawText: string): (boolean, string?)
	if _busy then
		return false, "track is busy; try again shortly"
	end
	_busy = true

	-- TODO: Phase 6 — drive the full state machine:
	-- 1. ParseRequest (RequestParser.parse)
	-- 2. AcquireTrack lock
	-- 3. GenerateInitialProposal (LLMAdapter.propose or hardcoded for no-LLM slice)
	-- 4. Loop: ApplyWorkingSector → RunVerification → EvaluateResult
	--      On success → Commit → done
	--      On failure and attempts < MAX_REPAIR_ATTEMPTS → AnalyzeFailure → ApplyRepair
	--      On exhaustion → Revert
	-- 5. Release lock

	_busy = false
	error("JobRunner.submit: not yet implemented")
end

-- Returns true if a job is currently running.
function JobRunner.isBusy(): boolean
	return _busy
end

return JobRunner
