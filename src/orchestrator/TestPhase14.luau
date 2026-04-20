-- TestPhase14.luau
-- Regression coverage for the tuned phase-14 reliability envelope.
-- Focus:
--   1. named golden obstacle profiles remain traversable under AttemptRunner
--   2. heuristic "add a jump to sector 2" converges to a committed RampJump
--   3. LLM repair partial-state responses are merged instead of failing on missing fields

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local T = require(script.Parent.TestUtils)
local LLMAdapter = require(script.Parent.Parent.Agent.LLMAdapter)
local RequestParser = require(script.Parent.Parent.Agent.RequestParser)
local AttemptRunner = require(script.Parent.AttemptRunner)
local RuntimeContext = require(script.Parent.RuntimeContext)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local SectorApplier = require(script.Parent.Parent.Track.SectorApplier)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)
local JobRunner = require(script.Parent.JobRunner)

type SectorState = Types.SectorState

local TestPhase14 = {}
local EDITABLE_SECTORS = { 2, 3, 4, 7, 8, 9 }
-- Golden obstacle profiles:
-- | Profile | Why it exists |
-- | RampJump sector 2 | Small but credible launch that clears the current airtime floor without tumbling; guards the basic jump JobRunner path. |
-- | Chicane sector 3 | Tightest currently reliable S-bend inside the real sector-length budget; guards against over-easing the shape into something trivial. |
-- | CrestDip sector 7 | Strong vertical feature that still reacquires cleanly under the retuned 100 studs/s verifier; guards against CrestDip regressions on either curvature or stability. |
local GOLDEN_RAMPJUMP_SECTOR2 = {
	ramp_angle = 9,
	ramp_length = 18,
	gap_length = 6,
	landing_length = 26,
	ingress = "None",
	egress = "Brake10",
}
local GOLDEN_CHICANE_SECTOR3 = {
	amplitude = 4,
	transition_length = 26,
	corridor_width = 18,
	ingress = "Brake25",
	egress = "Brake10",
}
local GOLDEN_CRESTDIP_SECTOR7 = {
	height_or_depth = 5,
	radius = 24,
	sector_length = 24,
	ingress = "Brake50",
	egress = "Brake10",
}

local function makeState(sectorId: number, mechanic, params, ingress, egress): SectorState
	return {
		sector_id = sectorId,
		mechanic = mechanic,
		params = params or {},
		pads = {
			ingress = ingress or "None",
			egress = egress or "None",
		},
		version = 0,
	}
end

local function getSectorMeta(sectorId: number)
	local sectors = TrackGenerator.generate()
	for _, sector in ipairs(sectors) do
		if sector.id == sectorId then
			return sector, sectors
		end
	end
	error("sector not found: " .. tostring(sectorId))
end

local function applyState(state: SectorState)
	local sector = getSectorMeta(state.sector_id)
	SectorApplier.apply(state, sector.entry, sector.exit)
end

local function resetEditableSectors()
	for _, sectorId in ipairs(EDITABLE_SECTORS) do
		local flatState = makeState(sectorId, nil, {}, "None", "None")
		applyState(flatState)
		SectorRegistry.commit(flatState)
	end
	task.wait(0.1)
end

local function runAttemptState(state: SectorState): (Types.RunResult, { string }, SectorState)
	local targetSector = getSectorMeta(state.sector_id)
	return AttemptRunner.run({
		workingState = state,
		action = nil,
		targetSectorId = state.sector_id,
		entryFrame = targetSector.entry,
		exitFrame = targetSector.exit,
		sectors = RuntimeContext.getSectors(),
		car = RuntimeContext.getCar(),
		canonicalStart = RuntimeContext.getCanonicalStart(),
		onSectorChange = nil,
	})
end

local function resultSummary(result: Types.RunResult): string
	local failureType = result.failure and result.failure.type or "nil"
	local failureDetail = result.failure and result.failure.detail or "nil"
	return string.format(
		"%s / %s entry=%.1f exit=%.1f progress=%.2f airborne=%s air=%.1f reacquired=%s slowdown=%.2f",
		tostring(failureType),
		tostring(failureDetail),
		result.metrics.entry_speed or 0,
		result.metrics.exit_speed or 0,
		result.metrics.target_progress or 0,
		tostring(result.metrics.target_airborne == true),
		result.metrics.target_air_distance or 0,
		tostring(result.metrics.target_reacquired == true),
		result.metrics.slowdown_ratio or 0
	)
end

local function waitForBaseline(): boolean
	local deadline = os.clock() + 60
	while os.clock() < deadline do
		if workspace:GetAttribute("AutoTrack_BaselineLapDone") == true then
			return true
		end
		task.wait(0.25)
	end
	return false
end

local function makeRequest(rawText: string)
	local request, err = RequestParser.parse(rawText, "phase14-req")
	assert(request ~= nil, "request parse failed: " .. tostring(err))
	return request
end

local function fakePacket(request, state, attemptIndex)
	return {
		request = request,
		sector_state = state,
		attempt_index = attemptIndex or 0,
		last_action = nil,
		run_result = {
			success = false,
			failure = { type = "local_execution_failure", sector_id = state.sector_id, detail = "tumble" },
			metrics = {
				entry_speed = 120,
				exit_speed = 0,
				airborne = true,
				air_distance = 0,
				lateral_error = 0,
				vertical_displacement = 0,
				reacquired = false,
				airtime_distance = 0,
				target_airborne = true,
				target_air_distance = 0,
				target_vertical_displacement = 0,
				target_reacquired = false,
				target_airtime_distance = 0,
				target_left_offset = 0,
				target_right_offset = 0,
				target_lateral_band_changes = 0,
				target_entered = true,
				target_exited = false,
				target_progress = 0.15,
				lap_time = 30,
				slowdown_ratio = 1.1,
			},
		},
		diagnostics = { failure_sector = state.sector_id, hints = { "tumble" } },
		legal_actions = { numeric_levers = { "ramp_angle", "ramp_length", "gap_length", "landing_length" }, pads = { "ingress", "egress" } },
	}
end

function TestPhase14.runUnit()
	local request = makeRequest("add a jump to sector 2")
	local currentState = makeState(2, "RampJump", {
		ramp_angle = 10,
		ramp_length = 16,
		gap_length = 6,
		landing_length = 24,
	}, "None", "None")

	LLMAdapter.setProvider("partial-repair-state", {
		propose = function()
			return HttpService:JSONEncode(currentState)
		end,
		repair = function()
			return HttpService:JSONEncode({
				newState = {
					params = {
						ramp_angle = 8,
						landing_length = 28,
					},
					pads = {
						ingress = "Brake10",
					},
				},
				explanation = "trimmed entry speed and lengthened landing",
			})
		end,
	})

	local action, newState, explanation, err = LLMAdapter.repair(fakePacket(request, currentState, 0), {})
	T.expect("phase14_partial_repair_state_action_nil", action == nil, tostring(action and action.type))
	T.expect("phase14_partial_repair_state_no_error", err == nil, tostring(err))
	T.expect("phase14_partial_repair_state_merged",
		newState ~= nil
			and newState.sector_id == 2
			and newState.mechanic == "RampJump"
			and newState.params.gap_length == 6
			and newState.params.ramp_angle == 8
			and newState.pads.ingress == "Brake10"
			and newState.pads.egress == "None",
		HttpService:JSONEncode(newState or {}))
	T.expect("phase14_partial_repair_state_explanation",
		type(explanation) == "string" and explanation ~= "",
		tostring(explanation))

	LLMAdapter.useMockProvider()
end

function TestPhase14.runIntegration()
	if workspace:GetAttribute("AutoTrack_BootBaselineSkipped") == true then
		T.fail("phase14_integration_requires_baseline", "restart without AutoTrack_SkipBootBaseline")
		return
	end
	if not waitForBaseline() then
		T.fail("phase14_baseline_ready", "baseline lap did not complete before tuning regression")
		return
	end

	resetEditableSectors()
	local rampState = makeState(2, "RampJump", {
		ramp_angle = GOLDEN_RAMPJUMP_SECTOR2.ramp_angle,
		ramp_length = GOLDEN_RAMPJUMP_SECTOR2.ramp_length,
		gap_length = GOLDEN_RAMPJUMP_SECTOR2.gap_length,
		landing_length = GOLDEN_RAMPJUMP_SECTOR2.landing_length,
	}, GOLDEN_RAMPJUMP_SECTOR2.ingress, GOLDEN_RAMPJUMP_SECTOR2.egress)
	local rampLap = select(1, runAttemptState(rampState))
	T.expect("phase14_golden_rampjump_sector2_succeeds",
		rampLap.success == true,
		"ramp lap failed: " .. resultSummary(rampLap))
	resetEditableSectors()

	local chicaneState = makeState(3, "Chicane", {
		amplitude = GOLDEN_CHICANE_SECTOR3.amplitude,
		transition_length = GOLDEN_CHICANE_SECTOR3.transition_length,
		corridor_width = GOLDEN_CHICANE_SECTOR3.corridor_width,
	}, GOLDEN_CHICANE_SECTOR3.ingress, GOLDEN_CHICANE_SECTOR3.egress)
	local chicaneLap = select(1, runAttemptState(chicaneState))
	T.expect("phase14_golden_chicane_sector3_succeeds",
		chicaneLap.success == true,
		"chicane lap failed: " .. resultSummary(chicaneLap))
	resetEditableSectors()

	local crestState = makeState(7, "CrestDip", {
		height_or_depth = GOLDEN_CRESTDIP_SECTOR7.height_or_depth,
		radius = GOLDEN_CRESTDIP_SECTOR7.radius,
		sector_length = GOLDEN_CRESTDIP_SECTOR7.sector_length,
	}, GOLDEN_CRESTDIP_SECTOR7.ingress, GOLDEN_CRESTDIP_SECTOR7.egress)
	local crestLap = select(1, runAttemptState(crestState))
	T.expect("phase14_golden_crestdip_sector7_succeeds",
		crestLap.success == true,
		"crest lap failed: " .. resultSummary(crestLap))
	resetEditableSectors()

	local ok, reason = JobRunner.submit("add a jump to sector 2")
	local job = JobRunner.getLastJob()
	local committed = SectorRegistry.getCommitted(2)
	T.expect("phase14_jobrunner_jump_sector2_commits",
		ok == true
			and reason == nil
			and job ~= nil
			and job.final_status == "committed"
			and committed ~= nil
			and committed.mechanic == "RampJump",
		string.format("ok=%s reason=%s final=%s mechanic=%s",
			tostring(ok),
			tostring(reason),
			tostring(job and job.final_status),
			tostring(committed and committed.mechanic)))
	resetEditableSectors()
end

function TestPhase14.run()
	TestPhase14.runUnit()
	TestPhase14.runIntegration()
end

return TestPhase14
