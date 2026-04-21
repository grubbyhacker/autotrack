local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RuntimeContext = require(script.Parent.RuntimeContext)
local Tracer = require(script.Parent.Tracer)
local UIState = require(script.Parent.UIState)
local JobLock = require(script.Parent.JobLock)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local SectorApplier = require(script.Parent.Parent.Track.SectorApplier)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)

local CameraDemo = {}

local _active = false
local _token = 0
local _priorStates = nil
local _restorePending = false
local _activePreset = "camera"

local DEMO_PRESETS = {
	camera = {
		label = "Camera demo",
		description = "Playable RampJump in sectors 3 and 7",
		stop_hint = "Submit '/demo camera' again to stop the demo",
		sectors = {
			[3] = {
				mechanic = "RampJump",
				params = {
					ramp_angle = 4,
					ramp_length = 24,
					gap_length = 2,
					landing_length = 34,
				},
				pads = {
					ingress = "Brake25",
					egress = "Brake10",
				},
			},
			[7] = {
				mechanic = "RampJump",
				params = {
					ramp_angle = 4,
					ramp_length = 24,
					gap_length = 2,
					landing_length = 34,
				},
				pads = {
					ingress = "Brake50",
					egress = "Brake25",
				},
			},
		},
	},
	rampitup = {
		label = "Ramp It Up demo",
		description = "Playable RampJump in sectors 3 and 8",
		stop_hint = "Submit '/demo rampitup' again to stop the demo",
		sectors = {
			[3] = {
				mechanic = "RampJump",
				params = {
					ramp_angle = 4,
					ramp_length = 24,
					gap_length = 2,
					landing_length = 36,
				},
				pads = {
					ingress = "Brake50",
					egress = "Brake25",
				},
			},
			[8] = {
				mechanic = "RampJump",
				params = {
					ramp_angle = 3,
					ramp_length = 26,
					gap_length = 2,
					landing_length = 40,
				},
				pads = {
					ingress = "Brake50",
					egress = "Brake25",
				},
			},
		},
	},
}

local function cloneParams(params)
	local copy = {}
	for key, value in pairs(params) do
		copy[key] = value
	end
	return copy
end

local function cloneState(state)
	return {
		sector_id = state.sector_id,
		mechanic = state.mechanic,
		params = cloneParams(state.params),
		pads = {
			ingress = state.pads.ingress,
			egress = state.pads.egress,
		},
		version = state.version,
	}
end

local function applyCommittedState(state)
	local targetSector = RuntimeContext.getSectorById(state.sector_id)
	SectorApplier.apply(state, targetSector.entry, targetSector.exit)
	SectorRegistry.commit(state)
end

local function restorePriorStates()
	if not _priorStates then
		return
	end
	for sectorId, state in pairs(_priorStates) do
		local restored = cloneState(state)
		restored.version = state.version + 1
		applyCommittedState(restored)
	end
	_priorStates = nil
	_restorePending = false
end

local function onSectorChange(id: number, entering: boolean)
	if entering then
		UIState.setCurrentSector(id)
	end
end

function CameraDemo.isActive(): boolean
	return _active
end

function CameraDemo.activePreset(): string
	return _activePreset
end

function CameraDemo.supportedPresets(): { string }
	local names = {}
	for name, _ in pairs(DEMO_PRESETS) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

function CameraDemo.start(options): (boolean, string?)
	options = options or {}
	if _active then
		return false, "camera demo already running"
	end
	assert(RuntimeContext.isReady(), "CameraDemo.start: runtime context not ready")
	local presetName = tostring(options.preset or "camera")
	local preset = DEMO_PRESETS[presetName]
	assert(preset ~= nil, "CameraDemo.start: unsupported preset " .. presetName)

	_active = true
	_token += 1
	local token = _token
	local loop = options.loop ~= false
	local runVerifier = options.runVerifier ~= false
	_restorePending = false
	_activePreset = presetName

	_priorStates = {}
	for sectorId, _ in pairs(preset.sectors) do
		local committed = SectorRegistry.getCommitted(sectorId)
		assert(committed ~= nil, "CameraDemo.start: missing committed state for sector " .. tostring(sectorId))
		_priorStates[sectorId] = cloneState(committed)
	end

	for sectorId, demoState in pairs(preset.sectors) do
		applyCommittedState({
			sector_id = sectorId,
			mechanic = demoState.mechanic,
			params = cloneParams(demoState.params),
			pads = {
				ingress = demoState.pads.ingress,
				egress = demoState.pads.egress,
			},
			version = (_priorStates[sectorId] and _priorStates[sectorId].version or 0) + 1,
		})
	end

	UIState.setPhase("CameraDemo", "Camera demo loop running")
	UIState.appendLog(string.format("%s enabled: %s", preset.label, preset.description))
	UIState.setExplanation(preset.stop_hint)
	Tracer.log("camera_demo_start " .. presetName)

	task.spawn(function()
		local lapIndex = 0
		local sectors = RuntimeContext.getSectors()
		local demoWaypoints, demoWaypointSectors, demoSectorKinds = TrackGenerator.getLapPath(sectors)
		local car = RuntimeContext.getCar()
		local startCF = RuntimeContext.getCanonicalStart()

		repeat
			if not runVerifier then
				break
			end
			if JobLock.isHeld() then
				task.wait(0.25)
			else
				assert(JobLock.tryAcquire(), "JobLock busy during camera demo")
				Tracer.log("camera_demo_lap_start " .. presetName)
				VerifierCar.reset(startCF)
				UIState.setPhase("CameraDemoLap", "Running camera demo lap...")
				local ok, result = pcall(function()
					return VerifierController.runLap(car, demoWaypoints, demoWaypointSectors, demoSectorKinds, onSectorChange)
				end)
				JobLock.release()

				if _restorePending then
					restorePriorStates()
				end

				if token ~= _token then
					break
				end

				if not ok then
					UIState.setPhase("CameraDemoFailure", "Camera demo lap failed")
					UIState.appendLog("Camera demo failed: " .. tostring(result))
					Tracer.log("camera_demo_lap_error " .. presetName)
					task.wait(0.5)
				elseif result.success then
					lapIndex += 1
					UIState.publishAttemptResult(result)
					UIState.setPhase("CameraDemo", "Camera demo loop running")
					UIState.appendLog(string.format("%s lap %d complete: %.2fs", preset.label, lapIndex, result.metrics.lap_time))
					Tracer.log(string.format("camera_demo_lap_complete %s %.2f", presetName, result.metrics.lap_time))
					task.wait(0.5)
				else
					UIState.setPhase("CameraDemoFailure", "Camera demo lap failed")
					UIState.appendLog("Camera demo failure: " .. tostring(result.failure and result.failure.type or "unknown"))
					Tracer.log("camera_demo_lap_failed " .. presetName)
					task.wait(0.5)
				end
			end
		until not loop or token ~= _token or not _active

		if token == _token and not loop then
			CameraDemo.stop()
		end
	end)

	return true, nil
end

function CameraDemo.stop(): (boolean, string?)
	if not _active then
		return false, "camera demo not running"
	end

	_active = false
	_token += 1
	if JobLock.isHeld() then
		_restorePending = true
	else
		restorePriorStates()
	end
	local stoppedPreset = _activePreset
	_activePreset = "camera"
	UIState.publishReady()
	UIState.appendLog(string.format("%s stopped", DEMO_PRESETS[stoppedPreset] and DEMO_PRESETS[stoppedPreset].label or "Camera demo"))
	Tracer.log("camera_demo_stop " .. stoppedPreset)
	return true, nil
end

return CameraDemo
