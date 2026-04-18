-- AttemptRunner.luau
-- Runs one simulation attempt (apply sector → run verifier → collect result).
-- prd_plan.md §7.3, Phase 6

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
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

function AttemptRunner.run(args): (RunResult, { string }, SectorState)
	local workingState = cloneState(args.workingState)
	if args.action then
		applyAction(workingState, args.action)
	end

	SectorApplier.apply(workingState, args.entryFrame, args.exitFrame)

	local stateOverrides = {}
	for _, state in ipairs(SectorRegistry.getStraights()) do
		if state.mechanic == "Chicane" then
			stateOverrides[state.sector_id] = state
		end
	end
	if workingState.mechanic == "Chicane" then
		stateOverrides[workingState.sector_id] = workingState
	end

	local waypoints, waypointSectors, sectorKinds = TrackGenerator.getLapPath(args.sectors, stateOverrides)
	VerifierCar.reset(args.canonicalStart)

	local rawResult = VerifierController.runLap(
		args.car,
		waypoints,
		waypointSectors,
		sectorKinds,
		args.onSectorChange,
		args.targetSectorId
	)

	local result, hints = LapEvaluator.evaluate(
		rawResult.failure,
		workingState,
		rawResult.metrics,
		args.targetSectorId
	)
	result.failure_position = rawResult.failure_position
	result.final_position = rawResult.final_position
	result.trajectory_tail = rawResult.trajectory_tail

	return result, hints, workingState
end

return AttemptRunner
