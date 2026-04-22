-- AttemptRunner.luau
-- Runs one simulation attempt (apply sector → run verifier → collect result).
-- prd_plan.md §7.3, Phase 6

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local ActionValidator = require(script.Parent.Parent.Agent.ActionValidator)
local SectorApplier = require(script.Parent.Parent.Track.SectorApplier)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)
local LapEvaluator = require(script.Parent.Parent.Integrity.LapEvaluator)

type SectorState  = Types.SectorState
type RunResult    = Types.RunResult
type AgentAction  = Types.AgentAction

local AttemptRunner = {}

local function cloneState(state: SectorState): SectorState
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

local function applyAction(state: SectorState, action: AgentAction)
	local ok, err = ActionValidator.validateAction(action, state.mechanic)
	assert(ok, "AttemptRunner.applyAction: " .. tostring(err))

	if action.type == "SetNumericLever" then
		state.params[action.lever] = action.value
	else
		state.pads[action.pad] = action.value
	end
end

local function getSectorMeta(sectors, targetSectorId: number)
	for _, sector in ipairs(sectors) do
		if sector.id == targetSectorId then
			return sector
		end
	end
	error("AttemptRunner.getSectorMeta: unknown sector " .. tostring(targetSectorId))
end

function AttemptRunner.run(args): (RunResult, { string }, SectorState)
	local workingState = cloneState(args.workingState)
	local runMode = args.mode or "full_lap"
	if args.action then
		applyAction(workingState, args.action)
	end

	local preflightResult, preflightHints = LapEvaluator.preflight(workingState, args.targetSectorId)
	if preflightResult then
		return preflightResult, preflightHints, workingState
	end

	SectorApplier.apply(workingState, args.entryFrame, args.exitFrame)

	local waypoints, waypointSectors, sectorKinds
	if runMode == "isolated_sector" then
		local targetSector = getSectorMeta(args.sectors, args.targetSectorId)
		waypoints, waypointSectors, sectorKinds = TrackGenerator.getSectorPath(targetSector, workingState)
		VerifierCar.reset(
			CFrame.new(
				targetSector.entry.Position + Vector3.new(0, (Constants.TRACK_THICKNESS * 0.5) + (Constants.CAR_HEIGHT * 0.5), 0)
			) * (targetSector.entry - targetSector.entry.Position)
		)
	else
		local stateOverrides = {}
		for _, state in ipairs(SectorRegistry.getStraights()) do
			if state.mechanic ~= nil then
				stateOverrides[state.sector_id] = state
			end
		end
		if workingState.mechanic ~= nil then
			stateOverrides[workingState.sector_id] = workingState
		end
		waypoints, waypointSectors, sectorKinds = TrackGenerator.getLapPath(args.sectors, stateOverrides)
		VerifierCar.reset(args.canonicalStart)
	end

	local rawResult = VerifierController.runLap(
		args.car,
		waypoints,
		waypointSectors,
		sectorKinds,
		args.onSectorChange,
		args.targetSectorId,
		workingState,
		args.entryFrame,
		{
			isolated_sector = runMode == "isolated_sector",
		}
	)

	local result, hints = LapEvaluator.evaluate(
		rawResult.failure,
		workingState,
		rawResult.metrics,
		args.targetSectorId,
		rawResult.integrity_hints
	)
	result.failure_position = rawResult.failure_position
	result.final_position = rawResult.final_position
	result.trajectory_tail = rawResult.trajectory_tail

	return result, hints, workingState
end

return AttemptRunner
