local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local LLMAdapter = require(script.Parent.Parent.Agent.LLMAdapter)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)
local JobLock = require(script.Parent.JobLock)
local RuntimeContext = require(script.Parent.RuntimeContext)
local UIState = require(script.Parent.UIState)
local ContinuousLapRunner = require(script.Parent.ContinuousLapRunner)
local Tracer = require(script.Parent.Tracer)

type OrchestratorContext = Types.OrchestratorContext
type OrchestratorDecision = Types.OrchestratorDecision

local OrchestratorAgent = {}

local EDITABLE_SECTORS = { 2, 3, 4, 7, 8, 9 }
local QUALIFIER_WORDS = {
	really = true,
	tall = true,
	long = true,
	short = true,
	steep = true,
	gentle = true,
	tight = true,
	wide = true,
	narrow = true,
	shallow = true,
	deep = true,
	extreme = true,
}
local MECHANIC_WORDS = {
	RampJump = "jump",
	Chicane = "chicane",
	CrestDip = "crest",
}

local _active = false

local function defaultEnsureBaseline(): (boolean, string?)
	if workspace:GetAttribute("AutoTrack_BaselineLapDone") == true then
		return true, nil
	end
	if not JobLock.tryAcquire() then
		return false, "track busy while recording baseline"
	end

	UIState.setPhase("BootBaseline", "Recording baseline lap...")
	UIState.appendLog("Baseline lap started on demand")
	Tracer.log("lap_start")

	local sectors = RuntimeContext.getSectors()
	local waypoints, waypointSectors, sectorKinds = TrackGenerator.getLapPath(sectors)
	local car = RuntimeContext.getCar()
	VerifierCar.reset(RuntimeContext.getCanonicalStart())

	local ok, result = pcall(function()
		return VerifierController.runLap(
			car,
			waypoints,
			waypointSectors,
			sectorKinds,
			function(id: number, entering: boolean)
				if entering then
					UIState.setCurrentSector(id)
				end
			end
		)
	end)
	JobLock.release()

	if not ok then
		return false, tostring(result)
	end
	if not result.success then
		return false, "baseline lap failed"
	end

	local lapTime = result.metrics.lap_time
	workspace:SetAttribute("AutoTrack_BaselineLapDone", true)
	workspace:SetAttribute("AutoTrack_BaselineLapTime", lapTime)
	UIState.setBaselineLapTime(lapTime)
	RuntimeContext.setBaselineLapTime(lapTime)
	UIState.appendLog(string.format("Baseline lap complete: %.2fs", lapTime))
	Tracer.log(string.format("lap_complete %.2f", lapTime))
	return true, nil
end

local function defaultDeps()
	return {
		ensureBaseline = defaultEnsureBaseline,
		orchestrate = function(context: OrchestratorContext)
			return LLMAdapter.orchestrate(context)
		end,
		setPhase = function(phase: string, label: string)
			UIState.setPhase(phase, label)
		end,
		setAttemptBudget = function(used: number, total: number)
			UIState.setEnduranceAttemptBudget(used, total)
		end,
		appendLog = function(line: string)
			UIState.appendLog(line)
		end,
		trace = function(line: string)
			Tracer.log(line)
		end,
		startContinuousLoop = function(initialLapCount: number)
			return ContinuousLapRunner.run({
				initialLapCount = initialLapCount,
			})
		end,
	}
end

local function budgetUsedFromSlowdown(slowdownRatio: number): number
	if Constants.ENDURANCE_LAP_TIME_BUDGET_RATIO <= 0 then
		return 0
	end
	return math.clamp(
		math.max(0, (slowdownRatio or 1) - 1) / Constants.ENDURANCE_LAP_TIME_BUDGET_RATIO,
		0,
		1
	)
end

local function buildContext(scoresBySector, slowdownRatio: number, attemptBudgetUsed: number, lastResult): OrchestratorContext
	local sectorStates = {}
	for _, state in ipairs(SectorRegistry.getStraights()) do
		sectorStates[state.sector_id] = {
			mechanic = state.mechanic,
			params = state.params,
			score = scoresBySector[state.sector_id] or 0,
		}
	end

	return {
		editable_sectors = EDITABLE_SECTORS,
		sector_states = sectorStates,
		budget = {
			used = budgetUsedFromSlowdown(slowdownRatio),
			over_budget = (slowdownRatio or 1) > (1 + Constants.ENDURANCE_LAP_TIME_BUDGET_RATIO),
		},
		attempt_budget = {
			used = attemptBudgetUsed,
			total = Constants.ENDURANCE_ATTEMPT_BUDGET,
		},
		last_result = lastResult,
	}
end

local function hintQualifiers(paramsHint: string?): string
	if type(paramsHint) ~= "string" then
		return ""
	end

	local picked = {}
	local seen = {}
	for word in string.gmatch(string.lower(paramsHint), "[%a%-]+") do
		if QUALIFIER_WORDS[word] and not seen[word] then
			seen[word] = true
			table.insert(picked, word)
		end
	end
	return table.concat(picked, " ")
end

local function buildRequestText(decision: OrchestratorDecision): string
	local mechanicWord = MECHANIC_WORDS[decision.mechanic] or "jump"
	local qualifiers = hintQualifiers(decision.params_hint)
	if qualifiers ~= "" then
		return string.format("add an %s %s in sector %d", qualifiers, mechanicWord, decision.sector_id)
	end
	return string.format("add a %s in sector %d", mechanicWord, decision.sector_id)
end

function OrchestratorAgent.isActive(): boolean
	return _active
end

function OrchestratorAgent.run(args): (boolean, string?)
	if _active then
		return false, "endurance mode already running"
	end
	if args.isCameraDemoActive and args.isCameraDemoActive() then
		return false, "camera demo running; toggle it off before /demo endurance"
	end
	assert(RuntimeContext.isReady(), "orchestrator requires runtime context")
	local deps = (args and args.deps) or defaultDeps()

	_active = true
	UIState.setEnduranceActive(true, Constants.ENDURANCE_ATTEMPT_BUDGET)
	UIState.setEnduranceAttemptBudget(0, Constants.ENDURANCE_ATTEMPT_BUDGET)
	UIState.setEnduranceLapCount(0)
	UIState.setBusy(true)
	UIState.appendLog("Endurance mode starting")
	Tracer.log("endurance_start")

	local ok, runOk, runReason = pcall(function()
		local baselineOk, baselineErr = deps.ensureBaseline()
		if not baselineOk then
			return false, baselineErr
		end

		local scoresBySector = {}
		local slowdownRatio = 1
		local attemptBudgetUsed = 0
		local lastResult = nil

		while attemptBudgetUsed < Constants.ENDURANCE_ATTEMPT_BUDGET do
			local context = buildContext(scoresBySector, slowdownRatio, attemptBudgetUsed, lastResult)
			deps.setPhase(
				"EnduranceOrchestrate",
				string.format("Endurance Mode — Orchestrating (%d/%d)", attemptBudgetUsed, Constants.ENDURANCE_ATTEMPT_BUDGET)
			)
			deps.setAttemptBudget(attemptBudgetUsed, Constants.ENDURANCE_ATTEMPT_BUDGET)

			local decision, orchestrateErr = deps.orchestrate(context)
			if not decision then
				return false, orchestrateErr
			end
			if decision.action == "begin_loop" then
				deps.appendLog("Orchestrator: begin loop")
				deps.trace("endurance_begin_loop")
				break
			end

			attemptBudgetUsed += 1
			deps.setAttemptBudget(attemptBudgetUsed, Constants.ENDURANCE_ATTEMPT_BUDGET)
			local requestText = buildRequestText(decision)
			deps.appendLog(string.format("Endurance %d/%d: %s", attemptBudgetUsed, Constants.ENDURANCE_ATTEMPT_BUDGET, requestText))
			deps.trace(string.format(
				"endurance_decision sector=%d mechanic=%s hint=%s used=%d",
				decision.sector_id or 0,
				tostring(decision.mechanic),
				tostring(decision.params_hint or "-"),
				attemptBudgetUsed
			))

			local submitOk, submitReason = args.submit(requestText)
			local job = args.getLastJob()
			if not submitOk then
				return false, submitReason
			end

			if job and job.request and job.request.parsed then
				local sectorId = job.request.parsed.sector_id
				local success = job.final_status == "committed"
				local latestAttempt = job.attempts[#job.attempts]
				local result = latestAttempt and latestAttempt.result or nil
				if result and result.metrics and result.metrics.slowdown_ratio then
					slowdownRatio = result.metrics.slowdown_ratio
				end
				if success and result and result.score then
					scoresBySector[sectorId] = result.score.total
				end
				lastResult = {
					sector_id = sectorId,
					success = success,
					score = success and (scoresBySector[sectorId] or 0) or 0,
					failure_reason = if success or not result or not result.failure then nil else tostring(result.failure.detail or result.failure.type),
				}
			end

			UIState.setBusy(true)
		end

		deps.setPhase("EnduranceLoop", "Endurance Mode — Continuous Build (lap 1)")
		deps.appendLog("Continuous loop armed")
		return deps.startContinuousLoop(0)
	end)

	UIState.setBusy(false)
	_active = false

	if not ok then
		UIState.setError("endurance failure: " .. tostring(runOk))
		Tracer.log("endurance_error " .. tostring(runOk))
		return false, tostring(runOk)
	end

	if runOk ~= true then
		UIState.setError("endurance failure: " .. tostring(runReason))
		Tracer.log("endurance_error " .. tostring(runReason))
	end

	return runOk, runReason
end

return OrchestratorAgent
