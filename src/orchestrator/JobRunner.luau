-- JobRunner.luau
-- Top-level CI job runner.  Drives the full propose → verify → repair → commit/revert loop.
-- prd_plan.md §7, Phase 6
--
-- Entry point: JobRunner.submit(rawText)
-- There is exactly one global job lock — concurrent submissions are rejected immediately.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local LLMConfig = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LLMConfig"))
local PadValueUtils = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("PadValueUtils"))
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
local UIState = require(script.Parent.UIState)
local CameraDemo = require(script.Parent.CameraDemo)
local ChallengeRunner = require(script.Parent.ChallengeRunner)
local MaximizerAgent = require(script.Parent.MaximizerAgent)
local TestDispatcher = require(script.Parent.TestDispatcher)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)

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

local function repairActionLabel(action): string
	if not action then
		return ""
	end
	if action.type == "SetPad" then
		local side = if action.pad == "ingress" then "ENTRY" else "EXIT"
		return string.format("%s %s", side, PadValueUtils.display(action.value))
	end

	local leverLabels = {
		ramp_angle = "RAMP ANGLE",
		ramp_length = "RAMP LENGTH",
		gap_length = "GAP LENGTH",
		landing_length = "LANDING LENGTH",
		amplitude = "AMPLITUDE",
		transition_length = "TRANSITION",
		corridor_width = "CORRIDOR",
		height_or_depth = "HEIGHT",
		radius = "RADIUS",
		sector_length = "FEATURE LENGTH",
	}
	return string.format("%s %s", leverLabels[action.lever] or string.upper(action.lever), tostring(action.value))
end

local function requestSummary(parsed): string
	if parsed.request_kind == "Pad" then
		return string.format("pad %s=%s", tostring(parsed.pad_side), tostring(parsed.pad_value))
	end
	return tostring(parsed.mechanic)
end

local function boolString(value): string
	return if value then "true" else "false"
end

local function qualifiersSummary(qualifiers): string
	if qualifiers == nil or #qualifiers == 0 then
		return "-"
	end
	return table.concat(qualifiers, ",")
end

local function failureDetail(result): string
	if result == nil or result.failure == nil or result.failure.detail == nil or result.failure.detail == "" then
		return "-"
	end
	return result.failure.detail
end

local function hintsSummary(hints): string
	if hints == nil or #hints == 0 then
		return "-"
	end
	return table.concat(hints, "|")
end

local function maximizeCampaignActive(): boolean
	return workspace:GetAttribute("AutoTrack_MaximizeCampaignActive") == true
end

local function shouldRunChallengeUp(request, result): (boolean, string?)
	if result == nil or result.score == nil then
		return false, "no_score"
	end
	if maximizeCampaignActive() then
		return false, "maximize_campaign"
	end

	for _, q in ipairs(request.qualifiers) do
		if q == "extreme" then
			return true, nil
		end
	end
	return false, "not_extreme"
end

local function shouldRevertPreTargetFailure(result, targetSectorId: number): boolean
	return result.failure ~= nil
		and result.failure.sector_id ~= targetSectorId
		and result.metrics.target_exited ~= true
end

local function attemptLimitForResult(result, targetSectorId: number): number
	if result.failure ~= nil
		and result.failure.sector_id == targetSectorId
		and (result.metrics.target_progress or 0) >= 0.5 then
		return Constants.MAX_REPAIR_ATTEMPTS + Constants.EXTRA_REPAIR_ATTEMPTS_AFTER_HALF_PROGRESS
	end
	return Constants.MAX_REPAIR_ATTEMPTS
end

local function stateSummary(state): string
	if state.mechanic ~= nil then
		return tostring(state.mechanic)
	end
	if state.pads.ingress ~= "None" or state.pads.egress ~= "None" then
		return string.format("pads ingress=%s egress=%s", state.pads.ingress, state.pads.egress)
	end
	return "flat"
end

local function finishRevert(job, targetSector, reason)
	SectorRollback.revert(job.request.parsed.sector_id, targetSector.entry, targetSector.exit)
	job.final_status = "reverted"
	Tracer.log(reason or string.format("revert sector=%d attempts=%d", job.request.parsed.sector_id, #job.attempts))
	Tracer.log(string.format("job_end id=%s status=reverted", job.job_id))
	UIState.appendLog("Reverted target sector")
	UIState.publishRevert()
	_lastJob = job
end

local function pauseForUI()
	task.wait(Constants.UI_PHASE_DELAY)
end

local function failureBannerText(result): string
	local failureType = result and result.failure and result.failure.type or "system_failure"
	if failureType == "mechanic_integrity_failure" then
		return "INTEGRITY FAIL"
	elseif failureType == "local_execution_failure" then
		return "TRAVERSAL FAIL"
	elseif failureType == "downstream_failure" then
		return "DOWNSTREAM FAIL"
	end
	return "SYSTEM FAIL"
end

local function pauseOnFailure(result)
	UIState.showFailureBanner(failureBannerText(result))
	local ok = pcall(function()
		VerifierCar.freeze()
	end)
	task.wait(Constants.UI_FAILURE_DWELL)
	if ok then
		pcall(function()
			VerifierCar.thaw()
		end)
	end
	UIState.hideFailureBanner()
end

local function parseSlashCommand(normalized: string): (string?, string?)
	local command, rest = string.match(normalized, "^/([%a_]+)%s*(.-)%s*$")
	if not command then
		return nil, nil
	end
	return command, rest
end

-- Submit a plain-text request.  Returns false + reason if rejected without running.
function JobRunner.submit(rawText: string): (boolean, string?)
	local sm = JobStateMachine.new()
	local requestId = nextId("req")
	local trimmed = string.match(rawText, "^%s*(.-)%s*$") or ""
	local lowered = string.lower(trimmed)
	local slashCommand, slashArg = parseSlashCommand(lowered)

	if slashCommand == "demo" then
		if slashArg == "camera" then
			if CameraDemo.isActive() then
				return CameraDemo.stop()
			end
			if JobLock.isHeld() then
				UIState.rejectRequest(rawText, "track is busy; try again shortly")
				return false, "track is busy; try again shortly"
			end
			return CameraDemo.start()
		end

		if slashArg == "crest" then
			if CameraDemo.isActive() then
				UIState.rejectRequest(rawText, "camera demo is running; toggle it off before /demo crest")
				return false, "camera demo is running; toggle it off before /demo crest"
			end
			if JobLock.isHeld() then
				UIState.rejectRequest(rawText, "track is busy; try again shortly")
				return false, "track is busy; try again shortly"
			end
			return JobRunner.submit("add a crest in sector 3")
		end

		if slashArg == "maximize" then
			if CameraDemo.isActive() then
				UIState.rejectRequest(rawText, "camera demo is running; toggle it off before /demo maximize")
				return false, "camera demo is running; toggle it off before /demo maximize"
			end
			if MaximizerAgent.isActive() then
				UIState.rejectRequest(rawText, "maximizer already running")
				return false, "maximizer already running"
			end
			task.spawn(function()
				MaximizerAgent.run({
					submit = JobRunner.submit,
					isBusy = JobRunner.isBusy,
					isCameraDemoActive = CameraDemo.isActive,
				})
			end)
			return true, nil
		end

		UIState.rejectRequest(rawText, "unknown demo; supported: /demo camera, /demo crest, /demo maximize")
		return false, "unknown demo; supported: /demo camera, /demo crest, /demo maximize"
	end

	if slashCommand == "llm" then
		local subcmd, rest2 = string.match(slashArg, "^(%S+)%s*(.-)%s*$")
		if subcmd == "on" then
			LLMConfig.setEnabled(true)
			local cfg = LLMConfig.get()
			UIState.setLLMConfig(true, cfg.modelId)
			UIState.appendLog("LLM enabled: " .. cfg.displayName)
			return true, nil
		elseif subcmd == "off" then
			LLMConfig.setEnabled(false)
			UIState.setLLMConfig(false, LLMConfig.get().modelId)
			UIState.appendLog("LLM disabled (heuristic)")
			return true, nil
		elseif subcmd == "model" then
			local modelId = rest2 or ""
			LLMConfig.setModel(modelId)
			local cfg = LLMConfig.get()
			UIState.setLLMConfig(cfg.enabled, cfg.modelId)
			UIState.appendLog("LLM model: " .. cfg.displayName)
			return true, nil
		end
		UIState.rejectRequest(rawText, "usage: /llm on | /llm off | /llm model <id>")
		return false, "usage: /llm on | /llm off | /llm model <id>"
	end

	if slashCommand == "test" then
		if slashArg == "" then
			UIState.rejectRequest(rawText, "test name missing; use /test <suite>")
			return false, "test name missing; use /test <suite>"
		end
		if CameraDemo.isActive() then
			UIState.rejectRequest(rawText, "camera demo is running; toggle it off before /test")
			return false, "camera demo is running; toggle it off before /test"
		end
		if JobLock.isHeld() then
			UIState.rejectRequest(rawText, "track is busy; try again shortly")
			return false, "track is busy; try again shortly"
		end

		UIState.setBusy(true)
		UIState.setPhase("RunTest", "Running server-side test...")
		UIState.appendLog("Running /test " .. slashArg)
		local snapshot = TestDispatcher.runSuite(slashArg)
		UIState.setBusy(false)
		if snapshot.status == "passed" then
			UIState.setPhase("RunTest", "Test passed")
			UIState.appendLog(string.format("Suite %s passed (%d pass)", slashArg, snapshot.pass_count))
			return true, nil
		end
		UIState.setPhase("RunTest", "Test failed")
		UIState.setError("test failed: " .. slashArg)
		UIState.appendLog(string.format(
			"Suite %s %s (%d fail, %d error)",
			slashArg,
			tostring(snapshot.status),
			snapshot.fail_count,
			snapshot.error_count
		))
		return false, "test failed: " .. slashArg
	end

	if CameraDemo.isActive() then
		UIState.rejectRequest(rawText, "camera demo is running; use /demo camera to toggle it off")
		return false, "camera demo is running; use /demo camera to toggle it off"
	end

	if JobLock.isHeld() then
		Tracer.log(string.format("job_reject reason=busy raw=%q", rawText))
		UIState.rejectRequest(rawText, "track is busy; try again shortly")
		return false, "track is busy; try again shortly"
	end

	sm:transition("ParseRequest")
	local request, parseErr = RequestParser.parse(rawText, requestId)
	if not request then
		Tracer.log(string.format("job_reject reason=%s raw=%q", tostring(parseErr), rawText))
		sm:transition("RejectRequest")
		sm:transition("Idle")
		UIState.rejectRequest(rawText, tostring(parseErr))
		return false, parseErr
	end

	if not JobLock.tryAcquire() then
		Tracer.log(string.format("job_reject reason=busy raw=%q", rawText))
		sm:transition("RejectRequest")
		sm:transition("Idle")
		UIState.rejectRequest(rawText, "track is busy; try again shortly")
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
			requestSummary(request.parsed)
		))
		UIState.beginJob(request)
		UIState.setPhase("AcquireTrack", "Preparing job")
		UIState.appendLog(string.format("Queued %s for sector %d", requestSummary(request.parsed), targetSectorId))
		pauseForUI()

		sm:transition("GenerateInitialProposal")
		UIState.setPhase("GenerateInitialProposal", "Generating proposal...")
		local initialState, proposalErr = LLMAdapter.propose(request)
		if not initialState then
			sm:transition("RejectRequest")
			sm:transition("Idle")
			UIState.rejectRequest(rawText, tostring(proposalErr))
			return false, proposalErr
		end

		local validState, validationErr = ActionValidator.validateSectorState(initialState)
		if not validState then
			sm:transition("RejectRequest")
			sm:transition("Idle")
			UIState.rejectRequest(rawText, "invalid initial proposal: " .. tostring(validationErr))
			return false, "invalid initial proposal: " .. tostring(validationErr)
		end
		UIState.appendLog("Initial proposal accepted")

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
			UIState.setPhase("ApplyWorkingSector", "Applying sector...")
			UIState.setAttempt(attemptIndex, Constants.MAX_REPAIR_ATTEMPTS)
			pauseForUI()
			sm:transition("RunVerification")
			UIState.setPhase("RunVerification", "Running simulation...")
			Tracer.log(string.format(
				"attempt index=%d sector=%d mechanic=%s",
				attemptIndex,
				targetSectorId,
				stateSummary(job.working_state)
			))

			local proposedState = cloneState(job.working_state)
			local result, hints, updatedState = AttemptRunner.run({
				workingState = job.working_state,
				action = nextAction,
				targetSectorId = targetSectorId,
				entryFrame = targetSector.entry,
				exitFrame = targetSector.exit,
				sectors = RuntimeContext.getSectors(),
				car = RuntimeContext.getCar(),
				canonicalStart = RuntimeContext.getCanonicalStart(),
				onSectorChange = function(id: number, entering: boolean)
					if entering then
						UIState.setCurrentSector(id)
					end
				end,
			})

			job.working_state = cloneState(updatedState)
			UIState.publishAttemptResult(result)
			table.insert(job.attempts, {
				attempt_index = attemptIndex,
				action = nextAction,
				proposed_state = proposedState,
				result = result,
				hints = hints,
			})
			Tracer.log(string.format(
				"attempt_result index=%d target_sector=%d success=%s failure_type=%s failure_sector=%s failure_detail=%s target_entered=%s target_exited=%s target_progress=%.2f score=%s",
				attemptIndex,
				targetSectorId,
				boolString(result.success),
				tostring(result.failure and result.failure.type or "none"),
				tostring(result.failure and result.failure.sector_id or "-"),
				failureDetail(result),
				boolString(result.metrics.target_entered == true),
				boolString(result.metrics.target_exited == true),
				result.metrics.target_progress or 0,
				tostring(result.score and result.score.total or "-")
			))

			sm:transition("EvaluateResult")
			if result.success then
				sm:transition("Commit")
				job.working_state.version = priorCommitted.version + 1
				SectorRegistry.commit(job.working_state)
				UIState.setSectorMechanic(targetSectorId, job.working_state.mechanic)
				job.final_status = "committed"
				UIState.setPhase("Commit", "Committed")
				UIState.appendLog(string.format("Committed %s v%d", stateSummary(job.working_state), job.working_state.version))
				if result.score then
					UIState.publishScore(targetSectorId, result.score)
					UIState.appendLog(string.format(
						"Score %.1f (air %.1f lat %.1f near %.1f cost %.1f budget %.0f%%%s)",
						result.score.total,
						result.score.air,
						result.score.lateral,
						result.score.near_miss,
						result.score.time_cost,
						result.score.budget_used * 100,
						if result.score.over_budget then " OVER" else ""
					))
				end
				pauseForUI()

				-- Phase 11b Stage B: opt-in challenge-up via the "extreme"
				-- qualifier. We already committed the minimum-valid state, so
				-- a failure here just stops escalation — the commit stands.
				local wantsChallengeUp, challengeSkipReason = shouldRunChallengeUp(request, result)
				if wantsChallengeUp then
					UIState.setPhase("ChallengeUp", "Challenging up...")
					UIState.appendLog("Escalating for extreme qualifier")
					local bestState, bestResult, rounds = ChallengeRunner.runUp({
						baseState = job.working_state,
						baseResult = result,
						targetSectorId = targetSectorId,
						targetSector = targetSector,
						sectors = RuntimeContext.getSectors(),
						car = RuntimeContext.getCar(),
						canonicalStart = RuntimeContext.getCanonicalStart(),
						onSectorChange = function(id, entering)
							if entering then UIState.setCurrentSector(id) end
						end,
						onRound = function(round, attempt, improved, reason)
							if attempt then
								UIState.appendLog(string.format(
									"Escalate r%d %s %s→%s %s%s",
									round,
									attempt.lever,
									tostring(attempt.from),
									tostring(attempt.to),
									if improved then "ACCEPT" else "REJECT",
									reason and (" (" .. reason .. ")") or ""
								))
							elseif reason then
								UIState.appendLog("Escalate stopped: " .. reason)
							end
						end,
					})
					if bestResult and bestResult.score and bestResult ~= result then
						bestState.version = job.working_state.version + 1
						SectorRegistry.commit(bestState)
						UIState.setSectorMechanic(targetSectorId, bestState.mechanic)
						job.working_state = cloneState(bestState)
						UIState.publishScore(targetSectorId, bestResult.score)
						UIState.appendLog(string.format(
							"Escalated in %d rounds → score %.1f (was %.1f)",
							rounds, bestResult.score.total, result.score.total
						))
						Tracer.log(string.format(
							"challenge_up sector=%d rounds=%d score=%.2f->%.2f",
							targetSectorId, rounds, result.score.total, bestResult.score.total
						))
					else
						UIState.appendLog(string.format("Escalate produced no net improvement in %d rounds", rounds))
					end
					pauseForUI()
				else
					Tracer.log(string.format(
						"challenge_up_skip sector=%d reason=%s qualifiers=%s",
						targetSectorId,
						tostring(challengeSkipReason or "unknown"),
						qualifiersSummary(request.qualifiers)
					))
				end

				UIState.publishCommit(targetSector)
				Tracer.log(string.format("commit sector=%d version=%d", targetSectorId, job.working_state.version))
				Tracer.log(string.format("job_end id=%s status=committed", job.job_id))
				_lastJob = job
				sm:transition("Idle")
				return true, nil
			end

			sm:transition("AnalyzeFailure")
			UIState.setPhase("AnalyzeFailure", "Analyzing failure...")
			UIState.showFailure(result)
			pauseOnFailure(result)
			UIState.appendLog(string.format(
				"Failure: %s in sector %d",
				tostring(result.failure and result.failure.type or "unknown"),
				result.failure and result.failure.sector_id or targetSectorId
			))
			Tracer.log(string.format(
				"failure_analysis target_sector=%d failure_type=%s failure_sector=%s failure_detail=%s target_entered=%s target_exited=%s target_progress=%.2f hints=%s",
				targetSectorId,
				tostring(result.failure and result.failure.type or "unknown"),
				tostring(result.failure and result.failure.sector_id or "-"),
				failureDetail(result),
				boolString(result.metrics.target_entered == true),
				boolString(result.metrics.target_exited == true),
				result.metrics.target_progress or 0,
				hintsSummary(hints)
			))
			pauseForUI()

			if shouldRevertPreTargetFailure(result, targetSectorId) then
				sm:transition("Revert")
				UIState.appendLog(string.format(
					"Target sector %d was never reached; reverting instead of repairing wrong sector",
					targetSectorId
				))
				finishRevert(
					job,
					targetSector,
					string.format(
						"revert sector=%d reason=pre_target_failure failure_sector=%d",
						targetSectorId,
						result.failure.sector_id
					)
				)
				sm:transition("Idle")
				return true, nil
			end

			local attemptLimit = attemptLimitForResult(result, targetSectorId)
			if attemptIndex >= attemptLimit then
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
			UIState.setPhase("ApplyRepair", "Applying repair...")
			local action, newState, explanation, repairErr = LLMAdapter.repair(packet, job.attempts)
			if repairErr then
				UIState.setError("LLM error: " .. repairErr)
				UIState.appendLog("LLM error: " .. repairErr)
				Tracer.log("llm_error attempt=" .. attemptIndex .. " err=" .. repairErr)
				sm:transition("Revert")
				finishRevert(job, targetSector, "revert reason=llm_error")
				sm:transition("Idle")
				return true, nil
			end

			if newState then
				-- LLM returned a full revised SectorState (no delta action)
				job.working_state = cloneState(newState)
				lastAction = nil
				nextAction = nil
				attemptIndex += 1
				UIState.setAttempt(attemptIndex, attemptLimitForResult(result, targetSectorId))
				UIState.setRepairAction("LLM: full state revision")
				UIState.setExplanation(explanation or "")
				UIState.appendLog(string.format("Attempt %d (LLM): %s", attemptIndex, explanation or "revised state"))
				pauseForUI()
				Tracer.log(string.format(
					"repair attempt=%d target_sector=%d failure_sector=%d failure_detail=%s path=llm_full_state explanation=%s",
					attemptIndex, targetSectorId, failureSector, failureDetail(result), explanation or "-"
				))
			elseif action then
				-- Heuristic returned a delta action
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
				UIState.setAttempt(attemptIndex, attemptLimitForResult(result, targetSectorId))
				UIState.setRepairAction(repairActionLabel(action))
				UIState.setExplanation(explanation or "")
				UIState.appendLog(string.format("Attempt %d: %s", attemptIndex, explanation or "repair"))
				pauseForUI()
				Tracer.log(string.format(
					"repair attempt=%d target_sector=%d failure_sector=%d failure_detail=%s target_entered=%s target_exited=%s target_progress=%.2f action=%s explanation=%s",
					attemptIndex, targetSectorId, failureSector, failureDetail(result),
					boolString(result.metrics.target_entered == true),
					boolString(result.metrics.target_exited == true),
					result.metrics.target_progress or 0,
					actionSummary(action), explanation or "repair"
				))
			else
				sm:transition("Revert")
				finishRevert(job, targetSector, "revert reason=empty_repair")
				sm:transition("Idle")
				return true, nil
			end
		end
	end)

	JobLock.release()
	if not ok then
		local err = tostring(resultOrErr)
		UIState.setBusy(false)
		UIState.setError("system failure: " .. err)
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

function JobRunner._shouldRunChallengeUp(request, result)
	return shouldRunChallengeUp(request, result)
end

function JobRunner._shouldRevertPreTargetFailure(result, targetSectorId: number): boolean
	return shouldRevertPreTargetFailure(result, targetSectorId)
end

function JobRunner._attemptLimitForResult(result, targetSectorId: number): number
	return attemptLimitForResult(result, targetSectorId)
end

return JobRunner
