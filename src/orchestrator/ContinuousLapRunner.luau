local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)
local JobLock = require(script.Parent.JobLock)
local RuntimeContext = require(script.Parent.RuntimeContext)
local UIState = require(script.Parent.UIState)
local HotfixAgent = require(script.Parent.HotfixAgent)
local Tracer = require(script.Parent.Tracer)

type RunResult = Types.RunResult

local ContinuousLapRunner = {}

local _active = false
local _stopRequested = false
local _lapCount = 0

local function cloneCommittedOverrides()
	local overrides = {}
	for _, state in ipairs(SectorRegistry.getStraights()) do
		if state.mechanic ~= nil then
			overrides[state.sector_id] = state
		end
	end
	return overrides
end

local function defaultIsTerminal(): boolean
	return UIState.getStateFolder():GetAttribute("endurance_terminal") == true
end

local function defaultRunLap(): RunResult
	local sectors = RuntimeContext.getSectors()
	local overrides = cloneCommittedOverrides()
	local waypoints, waypointSectors, sectorKinds = TrackGenerator.getLapPath(sectors, overrides)
	local car = RuntimeContext.getCar()
	VerifierCar.reset(RuntimeContext.getCanonicalStart())
	return VerifierController.runLap(
		car,
		waypoints,
		waypointSectors,
		sectorKinds,
		function(id: number, entering: boolean)
			if entering then
				UIState.setCurrentSector(id)
			end
		end,
		nil,
		nil,
		nil
	)
end

local function defaultDeps()
	return {
		tryAcquire = function()
			return JobLock.tryAcquire()
		end,
		release = function()
			JobLock.release()
		end,
		wait = function(seconds: number)
			task.wait(seconds)
		end,
		runLap = defaultRunLap,
		setPhase = function(phase: string, label: string)
			UIState.setPhase(phase, label)
		end,
		appendLog = function(line: string)
			UIState.appendLog(line)
		end,
		publishAttemptResult = function(result: RunResult)
			UIState.publishAttemptResult(result)
		end,
		setLapCount = function(count: number)
			UIState.setEnduranceLapCount(count)
		end,
		isTerminal = defaultIsTerminal,
		hotfixRun = function(sectorId: number, failureResult: RunResult)
			return HotfixAgent.run(sectorId, failureResult, nil, nil, nil)
		end,
		trace = function(line: string)
			Tracer.log(line)
		end,
	}
end

local function failureSector(result: RunResult?): number?
	if result == nil or result.failure == nil then
		return nil
	end
	return result.failure.sector_id
end

local function runManagedLap(deps): RunResult?
	while not _stopRequested do
		if deps.tryAcquire() then
			local ok, result = pcall(deps.runLap)
			deps.release()
			if not ok then
				error(result)
			end
			return result
		end
		deps.wait(0.1)
	end
	return nil
end

local function publishLapSuccess(deps, result: RunResult, prefix: string?)
	_lapCount += 1
	deps.setLapCount(_lapCount)
	deps.publishAttemptResult(result)
	local lapTime = result.metrics and result.metrics.lap_time or -1
	local slowdown = result.metrics and result.metrics.slowdown_ratio or -1
	local logPrefix = prefix or "Endurance lap"
	deps.appendLog(string.format("%s %d complete: %.2fs", logPrefix, _lapCount, lapTime))
	deps.trace(
		string.format("endurance_lap_complete count=%d lap_time=%.2f slowdown=%.3f", _lapCount, lapTime, slowdown)
	)
end

function ContinuousLapRunner._resolveHotfixSector(firstFailure: RunResult?, retryFailure: RunResult?): number?
	local retrySector = failureSector(retryFailure)
	if retrySector ~= nil then
		return retrySector
	end
	return failureSector(firstFailure)
end

function ContinuousLapRunner.isActive(): boolean
	return _active
end

function ContinuousLapRunner.getLapCount(): number
	return _lapCount
end

function ContinuousLapRunner.stop(): boolean
	if not _active then
		return false
	end
	_stopRequested = true
	return true
end

function ContinuousLapRunner.run(args): (boolean, string?)
	if _active then
		return false, "continuous lap runner already active"
	end
	assert(RuntimeContext.isReady() or (args and args.deps ~= nil), "continuous lap runner requires runtime context")

	args = args or {}
	local deps = args.deps or defaultDeps()
	local maxCleanLaps = args.maxCleanLaps
	local initialLapCount = args.initialLapCount or 0

	_active = true
	_stopRequested = false
	_lapCount = initialLapCount
	deps.setLapCount(_lapCount)

	local ok, err = pcall(function()
		while not _stopRequested do
			deps.setPhase("EnduranceLoop", string.format("Endurance Mode — Continuous Build (lap %d)", _lapCount + 1))
			local result = runManagedLap(deps)
			if result == nil then
				break
			end

			if result.success then
				publishLapSuccess(deps, result)
			else
				deps.publishAttemptResult(result)
				local firstSector = failureSector(result) or 0
				deps.appendLog(string.format("Endurance failure in sector %d — retrying lap", firstSector))
				deps.trace(string.format("endurance_retry sector=%d", firstSector))

				local retryResult = runManagedLap(deps)
				if retryResult == nil then
					break
				end

				if retryResult.success then
					publishLapSuccess(deps, retryResult, "Retry lap")
				else
					deps.publishAttemptResult(retryResult)
					local hotfixSector = ContinuousLapRunner._resolveHotfixSector(result, retryResult) or firstSector
					deps.appendLog(string.format("Failure persisted — entering hotfix for sector %d", hotfixSector))
					deps.trace(string.format("endurance_hotfix sector=%d", hotfixSector))
					local hotfixOk = deps.hotfixRun(hotfixSector, retryResult)
					if hotfixOk ~= true or deps.isTerminal() then
						break
					end
				end
			end

			if maxCleanLaps and _lapCount >= maxCleanLaps then
				break
			end
		end
	end)

	_active = false
	_stopRequested = false

	if not ok then
		local reason = tostring(err)
		if args.deps == nil then
			UIState.setError("continuous loop failure: " .. reason)
		end
		Tracer.log("endurance_loop_error " .. reason)
		return false, reason
	end

	return true, nil
end

function ContinuousLapRunner.start(args): (boolean, string?)
	if _active then
		return false, "continuous lap runner already active"
	end

	task.spawn(function()
		local ok, reason = ContinuousLapRunner.run(args)
		if not ok then
			Tracer.log("endurance_loop_stopped reason=" .. tostring(reason))
		end
	end)

	return true, nil
end

return ContinuousLapRunner
