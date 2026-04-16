-- AttemptRunner.luau
-- Runs one simulation attempt (apply sector → run verifier → collect result).
-- prd_plan.md §7.3, Phase 6

local Types = require(script.Parent.Parent.common.Types)
local SectorApplier   = require(script.Parent.Parent.track.SectorApplier)
local VerifierCar     = require(script.Parent.Parent.verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.verifier.VerifierController)
local MetricCollector = require(script.Parent.Parent.verifier.MetricCollector)
local FailureDetector = require(script.Parent.Parent.verifier.FailureDetector)
local LapEvaluator    = require(script.Parent.Parent.integrity.LapEvaluator)

type SectorState  = Types.SectorState
type RunResult    = Types.RunResult
type AgentAction  = Types.AgentAction

local AttemptRunner = {}

-- Apply action to working state (if provided), then run a full-lap simulation.
-- Returns (RunResult, updatedSectorState).
function AttemptRunner.run(
	workingState: SectorState,
	action: AgentAction?,
	entryFrame: CFrame,
	exitFrame: CFrame,
	canonicalStart: CFrame,
	baselineLapTime: number
): (RunResult, SectorState)
	-- TODO: Phase 6
	-- 1. If action provided, apply it to workingState (clone first)
	-- 2. SectorApplier.apply(workingState, entryFrame, exitFrame)
	-- 3. VerifierCar.resetTo(canonicalStart)
	-- 4. MetricCollector.reset()
	-- 5. VerifierController.start(centerlineProvider)
	-- 6. Wait for lap completion or FailureDetector to fire
	-- 7. VerifierController.stop()
	-- 8. metrics = MetricCollector.finalise(...)
	-- 9. result = LapEvaluator.evaluate(lapFailure, workingState, metrics)
	-- 10. return result, workingState
	error("AttemptRunner.run: not yet implemented")
end

return AttemptRunner
