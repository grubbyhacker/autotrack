-- HotfixAgent.luau
-- Emergency repair for a committed sector that has started failing.
-- Called by JobRunner when a committed sector fails on two consecutive laps.
--
-- Constraints:
--   - Only param adjustments and pad changes are allowed.
--   - The mechanic type must not change and may not be removed.
--   - Max HOTFIX_MAX_ATTEMPTS repair iterations.
--
-- On success: commits the fixed state, re-records baseline, dequeues pending job.
-- On failure: marks session as terminal.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local LLMAdapter = require(script.Parent.Parent.Agent.LLMAdapter)
local ActionValidator = require(script.Parent.Parent.Agent.ActionValidator)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local SectorRollback = require(script.Parent.Parent.Track.SectorRollback)
local LapEvaluator = require(script.Parent.Parent.Integrity.LapEvaluator)
local AttemptRunner = require(script.Parent.AttemptRunner)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)
local RuntimeContext = require(script.Parent.RuntimeContext)
local JobLock = require(script.Parent.JobLock)
local UIState = require(script.Parent.UIState)
local Tracer = require(script.Parent.Tracer)

type SectorState = Types.SectorState
type RunResult = Types.RunResult

local HotfixAgent = {}

local _active = false

function HotfixAgent.isActive(): boolean
	return _active
end

local function cloneState(state: SectorState): SectorState
	local params = {}
	for key, value in pairs(state.params) do
		params[key] = value
	end
	return {
		sector_id = state.sector_id,
		mechanic = state.mechanic,
		params = params,
		pads = { ingress = state.pads.ingress, egress = state.pads.egress },
		version = state.version,
	}
end

-- Re-run a full baseline lap over the current committed track (all sectors).
-- Returns the new lap time on success, nil on failure.
local function rerecordBaseline(): number?
	local sectors = RuntimeContext.getSectors()
	local car = RuntimeContext.getCar()
	local stateOverrides = {}
	for _, state in ipairs(SectorRegistry.getStraights()) do
		if state.mechanic ~= nil then
			stateOverrides[state.sector_id] = state
		end
	end
	local waypoints, waypointSectors, sectorKinds = TrackGenerator.getLapPath(sectors, stateOverrides)
	VerifierCar.reset(RuntimeContext.getCanonicalStart())
	local ok, result = pcall(function()
		return VerifierController.runLap(car, waypoints, waypointSectors, sectorKinds, function(id, entering)
			if entering then UIState.setCurrentSector(id) end
		end)
	end)
	if ok and result.success then
		return result.metrics.lap_time
	end
	return nil
end

-- Run HotfixAgent for a specific committed sector that is failing.
-- Args:
--   sectorId      — the committed sector that needs repair
--   failureResult — the RunResult that triggered hotfix
--   getPending    — function() -> (rawText?) returns the queued job text (or nil)
--   clearPending  — function() clears the queued job
--   resubmit      — function(rawText) re-submits the dequeued job
function HotfixAgent.run(sectorId: number, failureResult: RunResult, getPending, clearPending, resubmit)
	if _active then
		Tracer.log("hotfix_agent_reject reason=already_active sector=" .. sectorId)
		return false
	end
	_active = true

	UIState.setHotfixActive(true, sectorId)
	UIState.setPhase("HotfixMode", string.format("HOTFIX MODE — Sector %d", sectorId))
	UIState.setAttempt(0, Constants.HOTFIX_MAX_ATTEMPTS)
	UIState.appendLog(string.format("Hotfix Mode: sector %d committed but failing", sectorId))
	Tracer.log(string.format("hotfix_start sector=%d", sectorId))

	local committedState = SectorRegistry.getCommitted(sectorId)
	if not committedState or committedState.mechanic == nil then
		Tracer.log("hotfix_abort reason=no_committed_mechanic sector=" .. sectorId)
		UIState.appendLog("Hotfix aborted: sector " .. sectorId .. " has no committed mechanic")
		UIState.setEnduranceTerminal(sectorId)
		UIState.setPhase("EnduranceFailed", "ENDURANCE FAILED")
		_active = false
		return false
	end

	local targetSector = RuntimeContext.getSectorById(sectorId)
	local workingState = cloneState(committedState)
	local attemptIndex = 0
	local lastResult = failureResult
	local history = {}

	local succeeded = false

	while attemptIndex < Constants.HOTFIX_MAX_ATTEMPTS do
		local hints = {}
		local extraDiagnostics = nil
		if lastResult.failure and lastResult.failure.sector_id ~= sectorId then
			local downstreamState = SectorRegistry.getCommitted(lastResult.failure.sector_id)
			if downstreamState and downstreamState.mechanic ~= nil then
				extraDiagnostics = {
					downstream_sector_state = cloneState(downstreamState),
				}
			end
		end

		-- Build failure packet with hotfix constraint injected into the description
		local packet = LapEvaluator.buildFailurePacket(
			{
				raw_text = string.format(
					"[HOTFIX] Repair sector %d — only parameter/pad changes allowed, do NOT change mechanic type",
					sectorId
				),
				parsed = {
					sector_id = sectorId,
					mechanic = committedState.mechanic,
					request_kind = "Mechanic",
				},
				request_id = string.format("hotfix-%d-a%d", sectorId, attemptIndex),
				qualifiers = {},
				timestamp = os.time(),
			},
			workingState,
			attemptIndex,
			nil,
			lastResult,
			sectorId,
			hints,
			extraDiagnostics
		)

		UIState.setPhase("HotfixRepair", string.format("Hotfix: attempt %d/%d", attemptIndex + 1, Constants.HOTFIX_MAX_ATTEMPTS))
		UIState.setAttempt(attemptIndex + 1, Constants.HOTFIX_MAX_ATTEMPTS)

		local action, newState, explanation, repairErr = LLMAdapter.repair(packet, history)
		if repairErr then
			Tracer.log(string.format("hotfix_repair_error sector=%d attempt=%d err=%s", sectorId, attemptIndex, repairErr))
			UIState.appendLog("Hotfix repair error: " .. repairErr)
			break
		end

		local nextAction = nil
		if newState then
			-- LLM returned full state — enforce mechanic-type invariant
			if newState.mechanic ~= committedState.mechanic then
				Tracer.log(string.format("hotfix_mechanic_violation sector=%d attempt=%d", sectorId, attemptIndex))
				UIState.appendLog("Hotfix: LLM attempted mechanic change — rejected")
				break
			end
			workingState = cloneState(newState)
		elseif action then
			local actionOk, actionErr = ActionValidator.validateAction(action, workingState.mechanic)
			if not actionOk then
				Tracer.log(string.format("hotfix_action_invalid sector=%d attempt=%d err=%s", sectorId, attemptIndex, tostring(actionErr)))
				UIState.appendLog("Hotfix: invalid action — " .. tostring(actionErr))
				break
			end
			nextAction = action
		else
			break
		end

		UIState.appendLog(string.format("Hotfix attempt %d: %s", attemptIndex + 1, explanation or "repair"))

		local result, evalHints, updatedState = AttemptRunner.run({
			workingState = workingState,
			action = nextAction,
			targetSectorId = sectorId,
			entryFrame = targetSector.entry,
			exitFrame = targetSector.exit,
			sectors = RuntimeContext.getSectors(),
			car = RuntimeContext.getCar(),
			canonicalStart = RuntimeContext.getCanonicalStart(),
			onSectorChange = function(id, entering)
				if entering then UIState.setCurrentSector(id) end
			end,
		})

		workingState = cloneState(updatedState)
		lastResult = result
		table.insert(history, {
			attempt_index = attemptIndex,
			action = nextAction,
			proposed_state = workingState,
			result = result,
			hints = evalHints,
		})
		attemptIndex += 1

		Tracer.log(string.format(
			"hotfix_attempt sector=%d attempt=%d success=%s",
			sectorId, attemptIndex, tostring(result.success)
		))

		if result.success then
			-- Commit the fixed state
			workingState.version = committedState.version + 1
			SectorRegistry.commit(workingState)
			UIState.setSectorMechanic(sectorId, workingState.mechanic)
			UIState.appendLog(string.format("Hotfix: sector %d repaired and committed (v%d)", sectorId, workingState.version))
			Tracer.log(string.format("hotfix_commit sector=%d version=%d", sectorId, workingState.version))

			-- Re-record baseline over the now-fixed track
			UIState.setPhase("HotfixBaseline", "Hotfix complete — re-recording baseline...")
			UIState.appendLog("Re-recording baseline lap...")
			local newBaseline = rerecordBaseline()
			if newBaseline then
				UIState.setBaselineLapTime(newBaseline)
				RuntimeContext.setBaselineLapTime(newBaseline)
				UIState.appendLog(string.format("Baseline updated: %.2fs", newBaseline))
				Tracer.log(string.format("hotfix_baseline baseline=%.2f", newBaseline))
			else
				UIState.appendLog("Baseline re-record failed — keeping prior baseline")
				Tracer.log("hotfix_baseline_failed")
			end

			succeeded = true
			break
		end
	end

	UIState.setHotfixActive(false, 0)

	if succeeded then
		-- Dequeue pending job if any
		local pending = getPending and getPending()
		if pending then
			clearPending()
			UIState.appendLog("Dequeued job — resuming: " .. pending)
			UIState.setPhase("DequeueJob", "Dequeued job — resuming sector")
			Tracer.log("hotfix_dequeue raw=" .. pending)
			task.wait(0.5)
			if resubmit then
				task.spawn(function()
					resubmit(pending)
				end)
			end
		else
			UIState.publishReady()
		end
		_active = false
		return true
	else
		-- Hotfix failed — terminal state
		Tracer.log(string.format("hotfix_failed sector=%d attempts=%d", sectorId, attemptIndex))
		UIState.setEnduranceTerminal(sectorId)
		UIState.setPhase("EnduranceFailed", "ENDURANCE FAILED")
		UIState.showFailureBanner(string.format("ENDURANCE FAILED — Sector %d unfixable", sectorId))
		UIState.appendLog(string.format("Hotfix exhausted — sector %d unfixable after %d attempts", sectorId, attemptIndex))
		_active = false
		return false
	end
end

return HotfixAgent
