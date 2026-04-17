-- JobRunner.luau
-- Top-level CI job runner.  Drives the full propose → verify → repair → commit/revert loop.
-- prd_plan.md §7, Phase 6
--
-- Entry point: JobRunner.submit(rawText)
-- There is exactly one global job lock — concurrent submissions are rejected immediately.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local LLMAdapter = require(script.Parent.Parent.Agent.LLMAdapter)
local RequestParser = require(script.Parent.Parent.Agent.RequestParser)
local ActionValidator = require(script.Parent.Parent.Agent.ActionValidator)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local SectorRollback = require(script.Parent.Parent.Track.SectorRollback)
local LapEvaluator = require(script.Parent.Parent.Integrity.LapEvaluator)
local AttemptRunner = require(script.Parent.AttemptRunner)
local JobStateMachine = require(script.Parent.JobStateMachine)
local JobLock = require(script.Parent.JobLock)
local RuntimeContext = require(script.Parent.RuntimeContext)
local Tracer = require(script.Parent.Tracer)

type CIJob = Types.CIJob

local JobRunner = {}
local _lastJob: CIJob? = nil
local _idCounter = 0

local function nextId(prefix: string): string
	_idCounter += 1
	return string.format("%s-%03d", prefix, _idCounter)
end

local function cloneState(state)
	local params = {}
	for key, value in pairs(state.params) do
		params[key] = value
	end
	return {
		sector_id = state.sector_id,
		mechanic = state.mechanic,
		params = params,
		pads = {
			ingress = state.pads.ingress,
			egress = state.pads.egress,
		},
		version = state.version,
	}
end

local function actionSummary(action)
	if not action then
		return "initial"
	end
	if action.type == "SetNumericLever" then
		return string.format("%s=%s", action.lever, tostring(action.value))
	end
	return string.format("%s=%s", action.pad, action.value)
end

local function finishRevert(job, targetSector, reason)
	SectorRollback.revert(job.request.parsed.sector_id, targetSector.entry, targetSector.exit)
	job.final_status = "reverted"
	Tracer.log(reason or string.format("revert sector=%d attempts=%d", job.request.parsed.sector_id, #job.attempts))
	Tracer.log(string.format("job_end id=%s status=reverted", job.job_id))
	_lastJob = job
end

-- Submit a plain-text request.  Returns false + reason if rejected without running.
function JobRunner.submit(rawText: string): (boolean, string?)
	local sm = JobStateMachine.new()
	local requestId = nextId("req")

	if JobLock.isHeld() then
		Tracer.log(string.format("job_reject reason=busy raw=%q", rawText))
		return false, "track is busy; try again shortly"
	end

	sm:transition("ParseRequest")
	local request, parseErr = RequestParser.parse(rawText, requestId)
	if not request then
		Tracer.log(string.format("job_reject reason=%s raw=%q", tostring(parseErr), rawText))
		sm:transition("RejectRequest")
		sm:transition("Idle")
		return false, parseErr
	end

	if not JobLock.tryAcquire() then
		Tracer.log(string.format("job_reject reason=busy raw=%q", rawText))
		sm:transition("RejectRequest")
		sm:transition("Idle")
		return false, "track is busy; try again shortly"
	end

	local ok, resultOrErr, reason = pcall(function()
		assert(RuntimeContext.isReady(), "runtime context not ready")

		sm:transition("AcquireTrack")
		local targetSectorId = request.parsed.sector_id
		local targetSector = RuntimeContext.getSectorById(targetSectorId)
		local priorCommitted = SectorRegistry.getCommitted(targetSectorId)
		assert(priorCommitted ~= nil, "no committed sector state for " .. tostring(targetSectorId))

		Tracer.log(string.format(
			"job_start id=%s sector=%d mechanic=%s",
			request.request_id,
			targetSectorId,
			request.parsed.mechanic
		))

		sm:transition("GenerateInitialProposal")
		local initialState, proposalErr = LLMAdapter.propose(request)
		if not initialState then
			sm:transition("RejectRequest")
			sm:transition("Idle")
			return false, proposalErr
		end

		local validState, validationErr = ActionValidator.validateSectorState(initialState)
		if not validState then
			sm:transition("RejectRequest")
			sm:transition("Idle")
			return false, "invalid initial proposal: " .. tostring(validationErr)
		end

		local job: CIJob = {
			job_id = request.request_id,
			request = request,
			initial_state = cloneState(initialState),
			working_state = cloneState(initialState),
			attempts = {},
			final_status = "reverted",
		}

		local nextAction = nil
		local attemptIndex = 0
		local lastAction = nil

		while true do
			sm:transition("ApplyWorkingSector")
			sm:transition("RunVerification")
			Tracer.log(string.format(
				"attempt index=%d sector=%d mechanic=%s",
				attemptIndex,
				targetSectorId,
				tostring(job.working_state.mechanic)
			))

			local result, hints, updatedState = AttemptRunner.run({
				workingState = job.working_state,
				action = nextAction,
				targetSectorId = targetSectorId,
				entryFrame = targetSector.entry,
				exitFrame = targetSector.exit,
				sectors = RuntimeContext.getSectors(),
				car = RuntimeContext.getCar(),
				canonicalStart = RuntimeContext.getCanonicalStart(),
				onSectorChange = nil,
			})

			job.working_state = cloneState(updatedState)
			table.insert(job.attempts, {
				attempt_index = attemptIndex,
				action = nextAction,
				result = result,
			})

			sm:transition("EvaluateResult")
			if result.success then
				sm:transition("Commit")
				job.working_state.version = priorCommitted.version + 1
				SectorRegistry.commit(job.working_state)
				job.final_status = "committed"
				Tracer.log(string.format("commit sector=%d version=%d", targetSectorId, job.working_state.version))
				Tracer.log(string.format("job_end id=%s status=committed", job.job_id))
				_lastJob = job
				sm:transition("Idle")
				return true, nil
			end

			sm:transition("AnalyzeFailure")
			if attemptIndex >= Constants.MAX_REPAIR_ATTEMPTS then
				sm:transition("Revert")
				finishRevert(job, targetSector, string.format("revert sector=%d attempts=%d", targetSectorId, #job.attempts))
				sm:transition("Idle")
				return true, nil
			end

			local failureSector = if result.failure then result.failure.sector_id else targetSectorId
			local packet = LapEvaluator.buildFailurePacket(
				request,
				job.working_state,
				attemptIndex,
				lastAction,
				result,
				failureSector,
				hints
			)

			sm:transition("ApplyRepair")
			local action, explanation, repairErr = LLMAdapter.repair(packet)
			if not action then
				sm:transition("Revert")
				finishRevert(job, targetSector, "revert reason=" .. tostring(repairErr))
				sm:transition("Idle")
				return true, nil
			end

			local actionOk, actionErr = ActionValidator.validateAction(action, job.working_state.mechanic)
			if not actionOk then
				sm:transition("Revert")
				finishRevert(job, targetSector, "revert reason=" .. tostring(actionErr))
				sm:transition("Idle")
				return true, nil
			end

			lastAction = action
			nextAction = action
			attemptIndex += 1
			Tracer.log(string.format(
				"repair attempt=%d action=%s explanation=%s",
				attemptIndex,
				actionSummary(action),
				explanation or "repair"
			))
		end
	end)

	JobLock.release()
	if not ok then
		local err = tostring(resultOrErr)
		if request then
			local targetSector = RuntimeContext.isReady() and RuntimeContext.getSectorById(request.parsed.sector_id) or nil
			if targetSector and _lastJob and _lastJob.job_id == request.request_id and _lastJob.final_status == "reverted" then
				return false, "system failure: " .. err
			end
			if targetSector then
				SectorRollback.revert(request.parsed.sector_id, targetSector.entry, targetSector.exit)
			end
		end
		return false, "system failure: " .. err
	end

	return resultOrErr, reason
end

-- Returns true if a job is currently running.
function JobRunner.isBusy(): boolean
	return JobLock.isHeld()
end

function JobRunner.getLastJob(): CIJob?
	return _lastJob
end

return JobRunner
