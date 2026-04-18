local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local T = require(script.Parent.TestUtils)
local RequestParser = require(script.Parent.Parent.Agent.RequestParser)
local JobStateMachine = require(script.Parent.JobStateMachine)
local RuntimeContext = require(script.Parent.RuntimeContext)
local MinimalProposer = require(script.Parent.MinimalProposer)
local JobRunner = require(script.Parent.JobRunner)
local JobLock = require(script.Parent.JobLock)
local Tracer = require(script.Parent.Tracer)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)

local TestPhase6 = {}

local function makeRequest(mechanic, rawText)
	local request, err = RequestParser.parse(rawText or ("add a jump in sector 3"), "test-request")
	assert(request ~= nil, "expected valid request: " .. tostring(err))
	if mechanic then
		request.parsed.mechanic = mechanic
	end
	return request
end

local function makeState(mechanic)
	local defaults = LevelMappings.DEFAULTS[mechanic]
	local params = {}
	for key, value in pairs(defaults) do
		params[key] = value
	end
	return {
		sector_id = 3,
		mechanic = mechanic,
		params = params,
		pads = { ingress = "None", egress = "None" },
		version = 0,
	}
end

local function makePacket(mechanic, failureType, hints, lastAction)
	return {
		request = makeRequest(mechanic),
		sector_state = makeState(mechanic),
		attempt_index = 0,
		last_action = lastAction,
		run_result = {
			success = false,
			failure = {
				type = failureType or "mechanic_integrity_failure",
				sector_id = 3,
			},
			metrics = {
				entry_speed = 40,
				exit_speed = 35,
				airborne = false,
				air_distance = 0,
				lateral_error = 0,
				vertical_displacement = 0,
				reacquired = true,
				lap_time = 25,
				slowdown_ratio = 1,
			},
		},
		diagnostics = {
			failure_sector = 3,
			hints = hints or {},
		},
		legal_actions = {
			numeric_levers = LevelMappings.NUMERIC_LEVERS[mechanic],
			pads = { "ingress", "egress" },
		},
	}
end

local function waitForBaseline(): boolean
	local deadline = os.clock() + 45
	while os.clock() < deadline do
		if workspace:GetAttribute("AutoTrack_BaselineLapDone") == true then
			return true
		end
		task.wait(0.25)
	end
	return false
end

function TestPhase6.runUnit()
	local parsed, err = RequestParser.parse("Add a jump in sector 3", "parser-basic")
	T.expect("parser_accept_basic",
		parsed ~= nil and parsed.parsed.sector_id == 3 and parsed.parsed.mechanic == "RampJump" and parsed.parsed.request_kind == "Mechanic",
		tostring(err)
	)

	local synonymCases = {
		{ text = "add a chicane in sector 3", mechanic = "Chicane" },
		{ text = "add an s-curve in sector 3", mechanic = "Chicane" },
		{ text = "add a crest in sector 3", mechanic = "CrestDip" },
		{ text = "add a dip in sector 3", mechanic = "CrestDip" },
		{ text = "add a ramp jump in sector 3", mechanic = "RampJump" },
	}
	for index, case in ipairs(synonymCases) do
		local request = RequestParser.parse(case.text, "syn-" .. index)
		T.expect(
			"parser_accept_synonyms_" .. index,
			request ~= nil and request.parsed.mechanic == case.mechanic,
			case.text
		)
	end

	local qualifierRequest = RequestParser.parse("Add a really tall jump in sector 4", "qualifiers")
	local qualifiers = qualifierRequest and table.concat(qualifierRequest.qualifiers, ",") or ""
	T.expect("parser_qualifiers_extracted",
		qualifierRequest ~= nil and string.find(qualifiers, "really", 1, true) and string.find(qualifiers, "tall", 1, true),
		qualifiers
	)

	local padRequest, padErr = RequestParser.parse("add boost pad to sector 2 exit", "pad-basic")
	T.expect("parser_accept_pad_request",
		padRequest ~= nil
			and padRequest.parsed.request_kind == "Pad"
			and padRequest.parsed.sector_id == 2
			and padRequest.parsed.pad_side == "egress"
			and padRequest.parsed.pad_value == "Boost",
		tostring(padErr)
	)

	local rejectCases = {
		{ name = "parser_reject_empty", text = "", err = "empty request" },
		{ name = "parser_reject_no_sector", text = "add a jump", err = "sector missing" },
		{ name = "parser_reject_multi_sector", text = "add a jump in sector 3 and sector 4", err = "multiple sectors referenced" },
		{ name = "parser_reject_corner", text = "add a jump in sector 1", err = "sector is not an editable straight" },
		{ name = "parser_reject_ambiguous", text = "add a jump and a chicane in sector 3", err = "ambiguous mechanic" },
		{ name = "parser_reject_unsupported", text = "add a loop in sector 3", err = "unsupported mechanic" },
		{ name = "parser_reject_pad_side_missing", text = "add boost pad to sector 2", err = "pad side missing" },
	}
	for index, case in ipairs(rejectCases) do
		local _, caseErr = RequestParser.parse(case.text, "reject-" .. index)
		T.expect(case.name, caseErr == case.err, tostring(caseErr))
	end

	local defaultsRequest = makeRequest(nil, "add a jump in sector 3")
	local initialState = MinimalProposer.initial(defaultsRequest)
	T.expect("proposer_initial_defaults",
		initialState ~= nil and initialState.params.ramp_angle == LevelMappings.DEFAULTS.RampJump.ramp_angle,
		tostring(initialState and initialState.params.ramp_angle)
	)

	local biasedRequest = makeRequest(nil, "add a tall jump in sector 3")
	local biasedState = MinimalProposer.initial(biasedRequest)
	T.expect("proposer_initial_bias",
		biasedState ~= nil and biasedState.params.ramp_angle > LevelMappings.DEFAULTS.RampJump.ramp_angle,
		tostring(biasedState and biasedState.params.ramp_angle)
	)

	local padStateRequest, padStateParseErr = RequestParser.parse("add boost pad to sector 2 exit", "pad-state")
	assert(padStateRequest ~= nil, "expected valid pad request: " .. tostring(padStateParseErr))
	local padState, padStateErr = MinimalProposer.initial(padStateRequest)
	T.expect("proposer_initial_pad_only",
		padState ~= nil
			and padStateErr == nil
			and padState.sector_id == 2
			and padState.mechanic == nil
			and padState.pads.egress == "Boost",
		tostring(padStateErr)
	)

	local rampAction = MinimalProposer.repair(makePacket("RampJump", "mechanic_integrity_failure", { "verifier never became airborne" }))
	T.expect("proposer_repair_rampjump_not_airborne",
		rampAction ~= nil
			and rampAction.type == "SetPad"
			and rampAction.pad == "ingress"
			and rampAction.value == "Boost",
		tostring(rampAction and rampAction.type == "SetPad" and rampAction.pad or rampAction and rampAction.lever)
	)

	local chicaneAction = MinimalProposer.repair(makePacket("Chicane", "mechanic_integrity_failure", { "lateral displacement too small" }))
	T.expect("proposer_repair_chicane_amplitude_low",
		chicaneAction ~= nil and chicaneAction.type == "SetNumericLever" and chicaneAction.lever == "amplitude",
		tostring(chicaneAction and chicaneAction.lever)
	)

	local chicanePadAction = MinimalProposer.repair(makePacket("Chicane", "mechanic_integrity_failure", { "entry unstable" }))
	T.expect("proposer_repair_chicane_can_brake_entry",
		chicanePadAction ~= nil and chicanePadAction.type == "SetPad" and chicanePadAction.pad == "ingress" and chicanePadAction.value == "Brake",
		tostring(chicanePadAction and chicanePadAction.type == "SetPad" and chicanePadAction.pad or chicanePadAction and chicanePadAction.lever)
	)

	local crestAction = MinimalProposer.repair(makePacket("CrestDip", "mechanic_integrity_failure", { "vertical displacement too small" }))
	T.expect("proposer_repair_crestdip_displacement_low",
		crestAction ~= nil and crestAction.type == "SetNumericLever" and crestAction.lever == "height_or_depth",
		tostring(crestAction and crestAction.lever)
	)

	local crestStallAction = MinimalProposer.repair(makePacket("CrestDip", "local_execution_failure", {}, nil))
	T.expect("proposer_repair_crestdip_stall_softens_shape",
		crestStallAction ~= nil
			and (
				(crestStallAction.type == "SetNumericLever" and (crestStallAction.lever == "height_or_depth" or crestStallAction.lever == "radius"))
				or (crestStallAction.type == "SetPad" and crestStallAction.pad == "ingress" and crestStallAction.value == "Boost")
			)
			and not (crestStallAction.type == "SetNumericLever" and crestStallAction.lever == "sector_length"),
		tostring(crestStallAction and crestStallAction.type == "SetNumericLever" and crestStallAction.lever or crestStallAction and crestStallAction.type)
	)

	local downstreamAction = MinimalProposer.repair(makePacket("RampJump", "downstream_failure", {}, nil))
	T.expect("proposer_repair_downstream_pads_brake",
		downstreamAction ~= nil and downstreamAction.type == "SetPad" and downstreamAction.pad == "egress" and downstreamAction.value == "Brake",
		tostring(downstreamAction and downstreamAction.type)
	)

	local noRepeatPacket = makePacket(
		"RampJump",
		"mechanic_integrity_failure",
		{ "verifier never became airborne" },
		{ type = "SetNumericLever", lever = "ramp_angle", value = 25 }
	)
	local noRepeatAction = MinimalProposer.repair(noRepeatPacket)
	T.expect("proposer_repair_no_repeat",
		noRepeatAction ~= nil and not (noRepeatAction.type == "SetNumericLever" and noRepeatAction.lever == "ramp_angle"),
		tostring(noRepeatAction and noRepeatAction.lever)
	)

	local sm = JobStateMachine.new()
	local legalOk = pcall(function()
		sm:transition("ParseRequest")
		sm:transition("AcquireTrack")
		sm:transition("GenerateInitialProposal")
		sm:transition("ApplyWorkingSector")
		sm:transition("RunVerification")
		sm:transition("EvaluateResult")
		sm:transition("Commit")
		sm:transition("Idle")
	end)
	T.expect("statemachine_legal", legalOk, "expected legal transition chain")

	local illegalOk = pcall(function()
		local bad = JobStateMachine.new()
		bad:transition("Commit")
	end)
	T.expect("statemachine_illegal", illegalOk == false, "expected illegal transition to throw")

	T.expect("runtime_context_roundtrip",
		RuntimeContext.isReady()
			and RuntimeContext.getBaselineLapTime() == (workspace:GetAttribute("AutoTrack_BaselineLapTime") or -1)
			and RuntimeContext.getCar() ~= nil
			and RuntimeContext.getSectorById(3) ~= nil,
		"runtime context not initialized"
	)
end

function TestPhase6.runIntegration()
	if workspace:GetAttribute("AutoTrack_BootBaselineSkipped") == true then
		T.fail("phase6_integration_requires_baseline", "restart without AutoTrack_SkipBootBaseline")
		return
	end
	if not waitForBaseline() then
		T.fail("phase6_baseline_ready", "baseline lap did not complete before integration tests")
		return
	end

	Tracer.clear()
	local okEmpty, emptyReason = JobRunner.submit("")
	T.expect("submit_rejects_empty", okEmpty == false and emptyReason == "empty request", tostring(emptyReason))

	Tracer.clear()
	assert(JobLock.tryAcquire(), "expected JobLock acquisition for busy test")
	local okBusy, busyReason = JobRunner.submit("add a jump in sector 3")
	JobLock.release()
	T.expect("submit_rejects_busy", okBusy == false and string.find(tostring(busyReason), "busy", 1, true) ~= nil, tostring(busyReason))

	Tracer.clear()
	local okPad, padReason = JobRunner.submit("add boost pad to sector 2 exit")
	local padCommit = SectorRegistry.getCommitted(2)
	T.expect("job_commits_pad_request",
		okPad == true
			and padReason == nil
			and padCommit ~= nil
			and padCommit.mechanic == nil
			and padCommit.pads.egress == "Boost"
			and padCommit.version == 1,
		tostring(padReason)
	)

	Tracer.clear()
	local okChicane, chicaneReason = JobRunner.submit("add a chicane in sector 3")
	local chicaneState = SectorRegistry.getCommitted(3)
	T.expect("job_commits_chicane",
		okChicane == true and chicaneReason == nil and chicaneState ~= nil and chicaneState.mechanic == "Chicane" and chicaneState.version == 1,
		tostring(chicaneReason)
	)

	Tracer.clear()
	local okVersion, versionReason = JobRunner.submit("add a wide chicane in sector 3")
	local versionState = SectorRegistry.getCommitted(3)
	T.expect("job_commit_bumps_version",
		okVersion == true
			and versionReason == nil
			and versionState ~= nil
			and versionState.mechanic == "Chicane"
			and versionState.version >= 2,
		string.format(
			"reason=%s mechanic=%s version=%s",
			tostring(versionReason),
			tostring(versionState and versionState.mechanic),
			tostring(versionState and versionState.version)
		)
	)

	Tracer.clear()
	local okCrest, crestReason = JobRunner.submit("add a crest in sector 3")
	local crestCommitState = SectorRegistry.getCommitted(3)
	local crestJob = JobRunner.getLastJob()
	T.expect("job_commits_crest_after_repair_chain",
		okCrest == true
			and crestReason == nil
			and crestJob ~= nil
			and crestJob.final_status == "committed"
			and #crestJob.attempts >= 2
			and crestCommitState ~= nil
			and crestCommitState.mechanic == "CrestDip",
		string.format("final_status=%s attempts=%d",
			tostring(crestJob and crestJob.final_status),
			crestJob and #crestJob.attempts or -1)
	)

	Tracer.clear()
	local okRevert, revertReason = JobRunner.submit("add a really tall steep short crest in sector 3")
	local revertedState = SectorRegistry.getCommitted(3)
	local lastJob = JobRunner.getLastJob()
	T.expect("job_reverts_on_exhaustion",
		okRevert == true
			and revertReason == nil
			and lastJob ~= nil
			and lastJob.final_status == "reverted"
			and revertedState ~= nil
			and revertedState.mechanic == "CrestDip",
		tostring(revertReason)
	)

	local trace = table.concat(Tracer.getLog(), "\n")
	T.expect("job_trace_brackets_present",
		string.find(trace, "job_start", 1, true) ~= nil
			and string.find(trace, "attempt index=0", 1, true) ~= nil
			and string.find(trace, "job_end", 1, true) ~= nil,
		trace
	)
end

function TestPhase6.run()
	TestPhase6.runUnit()
	TestPhase6.runIntegration()
end

return TestPhase6
