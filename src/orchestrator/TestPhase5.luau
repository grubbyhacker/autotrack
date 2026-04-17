-- TestPhase5.luau
-- Verifies Phase 5 deliverables: mechanic integrity evaluators and LapEvaluator wiring.
-- All tests are unit tests (synthetic metrics/state) — SkipBootBaseline compatible.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local T = require(script.Parent.TestUtils)
local RampJumpIntegrity = require(script.Parent.Parent.Integrity.RampJumpIntegrity)
local ChicaneIntegrity  = require(script.Parent.Parent.Integrity.ChicaneIntegrity)
local CrestDipIntegrity = require(script.Parent.Parent.Integrity.CrestDipIntegrity)
local LapEvaluator      = require(script.Parent.Parent.Integrity.LapEvaluator)
local LevelMappings     = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))

local TestPhase5 = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function makeMetrics(overrides)
	overrides = overrides or {}
	return {
		entry_speed            = overrides.entry_speed or 40,
		exit_speed             = overrides.exit_speed or 38,
		airborne               = overrides.airborne or false,
		air_distance           = overrides.air_distance or 0,
		lateral_error          = overrides.lateral_error or 0,
		vertical_displacement  = overrides.vertical_displacement or 0,
		reacquired             = if overrides.reacquired ~= nil then overrides.reacquired else true,
		lap_time               = overrides.lap_time or 25,
		slowdown_ratio         = overrides.slowdown_ratio or 1,
	}
end

local function makeRampJumpState(overrides)
	overrides = overrides or {}
	return {
		sector_id = overrides.sector_id or 2,
		mechanic  = "RampJump",
		params    = {
			ramp_angle      = overrides.ramp_angle or 20,
			ramp_length     = overrides.ramp_length or 12,
			gap_length      = if overrides.gap_length ~= nil then overrides.gap_length else 8,
			landing_length  = overrides.landing_length or 12,
		},
		pads    = { ingress = "None", egress = "None" },
		version = 1,
	}
end

local function makeChicaneState(overrides)
	overrides = overrides or {}
	return {
		sector_id = overrides.sector_id or 2,
		mechanic  = "Chicane",
		params    = {
			amplitude          = if overrides.amplitude ~= nil then overrides.amplitude else 8,
			transition_length  = if overrides.transition_length ~= nil then overrides.transition_length else 15,
			corridor_width     = overrides.corridor_width or 14,
		},
		pads    = { ingress = "None", egress = "None" },
		version = 1,
	}
end

local function makeCrestDipState(overrides)
	overrides = overrides or {}
	return {
		sector_id = overrides.sector_id or 2,
		mechanic  = "CrestDip",
		params    = {
			height_or_depth  = if overrides.height_or_depth ~= nil then overrides.height_or_depth else 6,
			radius           = overrides.radius or 20,
			sector_length    = overrides.sector_length or 40,
		},
		pads    = { ingress = "None", egress = "None" },
		version = 1,
	}
end

local function makeRequest()
	return {
		request_id = "test-001",
		raw_text   = "add a ramp jump to sector 2",
		parsed     = { sector_id = 2, mechanic = "RampJump" },
		qualifiers = {},
		timestamp  = os.time(),
	}
end

-- ── RampJumpIntegrity unit tests ───────────────────────────────────────────────

local function testRampJump()
	local ok, hints

	-- pass: valid geometry + airborne + reacquired
	ok, hints = RampJumpIntegrity.evaluate(
		makeRampJumpState(),
		makeMetrics({ airborne = true, air_distance = 10, reacquired = true })
	)
	T.expect("rampjump_pass", ok == true, "expected pass, got hints: " .. table.concat(hints, "; "))

	-- fail: gap_length below minimum
	ok, hints = RampJumpIntegrity.evaluate(
		makeRampJumpState({ gap_length = 1 }),
		makeMetrics({ airborne = true, air_distance = 10, reacquired = true })
	)
	T.expect("rampjump_fail_gap", ok == false and #hints > 0,
		"expected fail on gap_length < " .. Constants.RAMPJUMP_MIN_GAP)

	-- fail: never airborne
	ok, hints = RampJumpIntegrity.evaluate(
		makeRampJumpState(),
		makeMetrics({ airborne = false, air_distance = 0 })
	)
	T.expect("rampjump_fail_not_airborne", ok == false and #hints > 0,
		"expected fail when airborne=false")

	-- fail: air_distance too short
	ok, hints = RampJumpIntegrity.evaluate(
		makeRampJumpState(),
		makeMetrics({ airborne = true, air_distance = 1 })
	)
	T.expect("rampjump_fail_air_distance", ok == false and #hints > 0,
		"expected fail when air_distance < " .. Constants.RAMPJUMP_MIN_AIR_DISTANCE)

	-- fail: no reacquisition
	ok, hints = RampJumpIntegrity.evaluate(
		makeRampJumpState(),
		makeMetrics({ airborne = true, air_distance = 10, reacquired = false })
	)
	T.expect("rampjump_fail_no_reacquire", ok == false and #hints > 0,
		"expected fail when reacquired=false")
end

-- ── ChicaneIntegrity unit tests ────────────────────────────────────────────────

local function testChicane()
	local ok, hints

	-- pass: amplitude=8, curvature=8/15=0.53 > 0.05
	ok, hints = ChicaneIntegrity.evaluate(makeChicaneState(), makeMetrics())
	T.expect("chicane_pass", ok == true, "expected pass, hints: " .. table.concat(hints, "; "))

	-- fail: amplitude below minimum
	ok, hints = ChicaneIntegrity.evaluate(
		makeChicaneState({ amplitude = 2 }),
		makeMetrics()
	)
	T.expect("chicane_fail_amplitude", ok == false and #hints > 0,
		"expected fail when amplitude < " .. Constants.CHICANE_MIN_LATERAL_DISPLACEMENT)

	-- fail: curvature below minimum (amplitude=4, transition_length=200 → 0.02 < 0.05)
	ok, hints = ChicaneIntegrity.evaluate(
		makeChicaneState({ amplitude = 4, transition_length = 200 }),
		makeMetrics()
	)
	T.expect("chicane_fail_curvature", ok == false and #hints > 0,
		"expected fail when effective curvature < " .. Constants.CHICANE_MIN_CURVATURE)
end

-- ── CrestDipIntegrity unit tests ───────────────────────────────────────────────

local function testCrestDip()
	local ok, hints

	-- pass: valid params + runtime displacement
	ok, hints = CrestDipIntegrity.evaluate(
		makeCrestDipState(),
		makeMetrics({ vertical_displacement = 5 })
	)
	T.expect("crestdip_pass", ok == true, "expected pass, hints: " .. table.concat(hints, "; "))

	-- fail: height_or_depth below minimum
	ok, hints = CrestDipIntegrity.evaluate(
		makeCrestDipState({ height_or_depth = 1 }),
		makeMetrics({ vertical_displacement = 5 })
	)
	T.expect("crestdip_fail_param", ok == false and #hints > 0,
		"expected fail when height_or_depth < " .. Constants.CRESTDIP_MIN_VERTICAL_DISPLACEMENT)

	-- fail: runtime vertical_displacement too small
	ok, hints = CrestDipIntegrity.evaluate(
		makeCrestDipState(),
		makeMetrics({ vertical_displacement = 0.5 })
	)
	T.expect("crestdip_fail_runtime", ok == false and #hints > 0,
		"expected fail when runtime vertical_displacement < " .. Constants.CRESTDIP_MIN_VERTICAL_DISPLACEMENT)

	-- fail: no reacquisition
	ok, hints = CrestDipIntegrity.evaluate(
		makeCrestDipState(),
		makeMetrics({ vertical_displacement = 5, reacquired = false })
	)
	T.expect("crestdip_fail_no_reacquire", ok == false and #hints > 0,
		"expected fail when reacquired=false")
end

-- ── LapEvaluator.evaluate unit tests ─────────────────────────────────────────

local function testEvaluator()
	local result, hints

	-- lap failure takes precedence over integrity
	result, hints = LapEvaluator.evaluate(
		{ type = "local_execution_failure", sector_id = 2 },
		makeRampJumpState(),
		makeMetrics({ airborne = true, air_distance = 10, reacquired = true }),
		2
	)
	T.expect("evaluator_lap_failure_takes_precedence",
		result.success == false
		and result.failure ~= nil
		and result.failure.type == "local_execution_failure"
		and #hints == 0,
		"expected local_execution_failure to take precedence, got: " .. tostring(result.failure and result.failure.type)
	)

	-- mechanic_integrity_failure — hints returned
	result, hints = LapEvaluator.evaluate(
		nil,
		makeRampJumpState({ gap_length = 1 }),
		makeMetrics({ airborne = true, air_distance = 10, reacquired = true }),
		2
	)
	T.expect("evaluator_integrity_fail_hints_returned",
		result.success == false
		and result.failure ~= nil
		and result.failure.type == "mechanic_integrity_failure"
		and #hints > 0,
		"expected mechanic_integrity_failure with non-empty hints"
	)

	-- success: valid state + good metrics
	result, hints = LapEvaluator.evaluate(
		nil,
		makeRampJumpState(),
		makeMetrics({ airborne = true, air_distance = 10, reacquired = true }),
		2
	)
	T.expect("evaluator_success",
		result.success == true and result.failure == nil and #hints == 0,
		"expected success=true for valid RampJump run"
	)

	-- downstream_failure reclassification: car failed in sector 5, target is sector 2
	result, hints = LapEvaluator.evaluate(
		{ type = "local_execution_failure", sector_id = 5 },
		makeRampJumpState(),
		makeMetrics(),
		2
	)
	T.expect("evaluator_downstream_reclassify",
		result.success == false
		and result.failure ~= nil
		and result.failure.type == "downstream_failure"
		and result.failure.sector_id == 5,
		"expected downstream_failure in sector 5, got: " .. tostring(result.failure and result.failure.type)
	)
end

-- ── LapEvaluator.buildFailurePacket unit tests ───────────────────────────────

local function testFailurePacket()
	local req = makeRequest()

	-- RampJump legal levers
	local rjState = makeRampJumpState()
	local rjResult = { success = false, failure = { type = "mechanic_integrity_failure", sector_id = 2 }, metrics = makeMetrics() }
	local packet = LapEvaluator.buildFailurePacket(req, rjState, 1, nil, rjResult, 2, { "gap too small" })

	local expectedRJ = LevelMappings.NUMERIC_LEVERS["RampJump"]
	local rjLeversMatch = #packet.legal_actions.numeric_levers == #expectedRJ
	if rjLeversMatch then
		for i, v in ipairs(expectedRJ) do
			if packet.legal_actions.numeric_levers[i] ~= v then
				rjLeversMatch = false
				break
			end
		end
	end
	T.expect("failurepacket_legal_levers_rampjump", rjLeversMatch,
		"expected RampJump levers: " .. table.concat(expectedRJ, ","))

	-- Chicane legal levers
	local chState = makeChicaneState()
	local chResult = { success = false, failure = { type = "mechanic_integrity_failure", sector_id = 2 }, metrics = makeMetrics() }
	local chPacket = LapEvaluator.buildFailurePacket(req, chState, 1, nil, chResult, 2, {})
	local expectedCh = LevelMappings.NUMERIC_LEVERS["Chicane"]
	local chLeversMatch = #chPacket.legal_actions.numeric_levers == #expectedCh
	T.expect("failurepacket_legal_levers_chicane", chLeversMatch,
		"expected Chicane levers: " .. table.concat(expectedCh, ","))

	-- CrestDip legal levers
	local cdState = makeCrestDipState()
	local cdResult = { success = false, failure = { type = "mechanic_integrity_failure", sector_id = 2 }, metrics = makeMetrics() }
	local cdPacket = LapEvaluator.buildFailurePacket(req, cdState, 1, nil, cdResult, 2, {})
	local expectedCd = LevelMappings.NUMERIC_LEVERS["CrestDip"]
	local cdLeversMatch = #cdPacket.legal_actions.numeric_levers == #expectedCd
	T.expect("failurepacket_legal_levers_crestdip", cdLeversMatch,
		"expected CrestDip levers: " .. table.concat(expectedCd, ","))

	-- pads always present
	local padsOk = packet.legal_actions.pads ~= nil
		and packet.legal_actions.pads[1] == "ingress"
		and packet.legal_actions.pads[2] == "egress"
	T.expect("failurepacket_pads_present", padsOk,
		"expected pads = { 'ingress', 'egress' }")

	-- hints are threaded through
	T.expect("failurepacket_hints_threaded",
		#packet.diagnostics.hints == 1 and packet.diagnostics.hints[1] == "gap too small",
		"expected hints to be forwarded into diagnostics"
	)
end

-- ── Master entry point ────────────────────────────────────────────────────────

function TestPhase5.runUnit()
	testRampJump()
	testChicane()
	testCrestDip()
	testEvaluator()
	testFailurePacket()
end

function TestPhase5.run()
	TestPhase5.runUnit()
end

return TestPhase5
