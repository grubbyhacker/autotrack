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
		airtime_distance       = overrides.airtime_distance or 0,
		target_airborne = if overrides.target_airborne ~= nil then overrides.target_airborne else nil,
		target_air_distance = overrides.target_air_distance,
		target_vertical_displacement = overrides.target_vertical_displacement,
		target_reacquired = overrides.target_reacquired,
		target_airtime_distance = overrides.target_airtime_distance,
		target_left_offset = overrides.target_left_offset,
		target_right_offset = overrides.target_right_offset,
		target_lateral_band_changes = overrides.target_lateral_band_changes,
		target_entered = if overrides.target_entered ~= nil then overrides.target_entered else true,
		target_exited = if overrides.target_exited ~= nil then overrides.target_exited else true,
		target_progress = if overrides.target_progress ~= nil then overrides.target_progress else 1,
		lap_time               = overrides.lap_time or 25,
		slowdown_ratio         = overrides.slowdown_ratio or 1,
		target_apex_min_speed  = overrides.target_apex_min_speed,
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
			height_or_depth  = if overrides.height_or_depth ~= nil then overrides.height_or_depth else 8,
			radius           = overrides.radius or 20,
			sector_length    = overrides.sector_length or 30,
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

	-- RampJump airtime boundary: stable sector-2 jumps currently live near 5 studs,
	-- so the integrity floor tracks that proven envelope instead of the abandoned
	-- phase-14 tightening to 10.
	ok, hints = RampJumpIntegrity.evaluateRuntime(
		makeMetrics({ target_airborne = true, target_air_distance = Constants.RAMPJUMP_MIN_AIR_DISTANCE - 0.1, target_reacquired = true })
	)
	T.expect("rampjump_fail_air_distance_just_below_min",
		ok == false and #hints > 0,
		"expected fail at air_distance = MIN - epsilon (got " .. tostring(Constants.RAMPJUMP_MIN_AIR_DISTANCE - 0.1) .. ")")

	ok, hints = RampJumpIntegrity.evaluateRuntime(
		makeMetrics({ target_airborne = true, target_air_distance = Constants.RAMPJUMP_MIN_AIR_DISTANCE, target_reacquired = true })
	)
	T.expect("rampjump_pass_air_distance_at_min",
		ok == true,
		"expected pass at air_distance = MIN (" .. tostring(Constants.RAMPJUMP_MIN_AIR_DISTANCE) .. ")")
end

-- ── ChicaneIntegrity unit tests ────────────────────────────────────────────────

local function testChicane()
	local ok, hints

	-- pass: valid geometry + target-sector lateral movement to both sides
	ok, hints = ChicaneIntegrity.evaluate(makeChicaneState(), makeMetrics({
		target_left_offset = 4,
		target_right_offset = 4,
		target_lateral_band_changes = 2,
	}))
	T.expect("chicane_pass", ok == true, "expected pass, hints: " .. table.concat(hints, "; "))

	-- fail: amplitude below minimum
	ok, hints = ChicaneIntegrity.evaluate(
		makeChicaneState({ amplitude = 2 }),
		makeMetrics({
			target_left_offset = 4,
			target_right_offset = 4,
			target_lateral_band_changes = 2,
		})
	)
	T.expect("chicane_fail_amplitude", ok == false and #hints > 0,
		"expected fail when amplitude < " .. Constants.CHICANE_MIN_LATERAL_DISPLACEMENT)

	-- fail: curvature below minimum (amplitude=4, transition_length=200 → 0.02 < 0.05)
	ok, hints = ChicaneIntegrity.evaluate(
		makeChicaneState({ amplitude = 4, transition_length = 200 }),
		makeMetrics({
			target_left_offset = 4,
			target_right_offset = 4,
			target_lateral_band_changes = 2,
		})
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

	-- fail: crest top crossed too slowly
	ok, hints = CrestDipIntegrity.evaluate(
		makeCrestDipState(),
		makeMetrics({ vertical_displacement = 5, reacquired = true, target_apex_min_speed = Constants.CRESTDIP_APEX_MIN_SPEED - 1 })
	)
	T.expect("crestdip_fail_apex_speed", ok == false and #hints > 0,
		"expected fail when crest apex speed is below minimum")
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

	-- upstream traversal failure before reaching the target must stay traversal,
	-- not get reclassified into a bogus target integrity failure.
	result, hints = LapEvaluator.evaluate(
		{ type = "local_execution_failure", sector_id = 1, detail = "no_progress" },
		makeCrestDipState(),
		makeMetrics({
			target_entered = false,
			target_exited = false,
			target_progress = 0,
			target_vertical_displacement = 0,
			target_reacquired = true,
		}),
		2
	)
	T.expect("evaluator_upstream_failure_not_reclassified_before_target_entry",
		result.success == false
		and result.failure ~= nil
		and result.failure.type == "local_execution_failure"
		and result.failure.sector_id == 1,
		"expected upstream local_execution_failure to survive before target entry")

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
		makeMetrics({ target_airborne = true, target_air_distance = 10, target_reacquired = true }),
		2
	)
	T.expect("evaluator_downstream_reclassify",
		result.success == false
		and result.failure ~= nil
		and result.failure.type == "downstream_failure"
		and result.failure.sector_id == 5,
		"expected downstream_failure in sector 5, got: " .. tostring(result.failure and result.failure.type)
	)

	-- if target-sector runtime telemetry already proves the RampJump is bad,
	-- preserve that as mechanic_integrity_failure instead of washing it into
	-- downstream_failure.
	result, hints = LapEvaluator.evaluate(
		{ type = "local_execution_failure", sector_id = 5 },
		makeRampJumpState(),
		makeMetrics({ target_airborne = false, target_air_distance = 0, target_reacquired = true }),
		2
	)
	T.expect("evaluator_target_runtime_overrides_downstream",
		result.success == false
		and result.failure ~= nil
		and result.failure.type == "mechanic_integrity_failure"
		and result.failure.sector_id == 2
		and #hints > 0,
		"expected target mechanic_integrity_failure, got: " .. tostring(result.failure and result.failure.type))

	result, hints = LapEvaluator.evaluate(
		{ type = "local_execution_failure", sector_id = 1 },
		makeRampJumpState(),
		makeMetrics({
			airborne = true,
			air_distance = 10,
			reacquired = true,
			target_entered = false,
			target_exited = false,
			target_progress = 0,
			target_airborne = nil,
			target_air_distance = nil,
			target_reacquired = nil,
		}),
		2
	)
	T.expect("evaluator_pre_target_failure_stays_non_target",
		result.success == false
		and result.failure ~= nil
		and result.failure.sector_id == 1
		and result.failure.type == "local_execution_failure",
		"expected non-target failure to remain non-target before target entry")
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
