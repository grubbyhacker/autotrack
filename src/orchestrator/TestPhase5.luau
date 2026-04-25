--!strict

-- TestPhase5.luau
-- Verifies Phase 5 deliverables: mechanic integrity evaluators and LapEvaluator wiring.
-- All tests are unit tests (synthetic metrics/state) — SkipBootBaseline compatible.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local T = require(script.Parent.TestUtils)
local RampJumpIntegrity = require(script.Parent.Parent.Integrity.RampJumpIntegrity)
local ChicaneIntegrity = require(script.Parent.Parent.Integrity.ChicaneIntegrity)
local CrestDipIntegrity = require(script.Parent.Parent.Integrity.CrestDipIntegrity)
local LapEvaluator = require(script.Parent.Parent.Integrity.LapEvaluator)
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))

type FailureInfo = Types.FailureInfo
type Request = Types.Request
type RunMetrics = Types.RunMetrics
type RunResult = Types.RunResult
type SectorState = Types.SectorState

type MetricsOverrides = {
	entry_speed: number?,
	exit_speed: number?,
	airborne: boolean?,
	air_distance: number?,
	lateral_error: number?,
	vertical_displacement: number?,
	reacquired: boolean?,
	airtime_distance: number?,
	target_airborne: boolean?,
	target_air_distance: number?,
	target_vertical_displacement: number?,
	target_reacquired: boolean?,
	target_airtime_distance: number?,
	target_left_offset: number?,
	target_right_offset: number?,
	target_lateral_band_changes: number?,
	target_entered: boolean?,
	target_exited: boolean?,
	target_progress: number?,
	target_reacquire_distance: number?,
	target_reacquire_lateral_offset: number?,
	target_peak_body_distance: number?,
	target_exit_angular_speed: number?,
	target_exit_vertical_speed: number?,
	target_touchdown_up_dot: number?,
	target_touchdown_down_speed: number?,
	target_apex_min_speed: number?,
	lap_time: number?,
	slowdown_ratio: number?,
}

type RampJumpOverrides = {
	sector_id: number?,
	ramp_angle: number?,
	ramp_length: number?,
	gap_length: number?,
	landing_length: number?,
}

type ChicaneOverrides = {
	sector_id: number?,
	amplitude: number?,
	transition_length: number?,
	corridor_width: number?,
}

type CrestDipOverrides = {
	sector_id: number?,
	height_or_depth: number?,
	radius: number?,
	sector_length: number?,
}

local TestPhase5 = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function makeMetrics(overrides: MetricsOverrides?): RunMetrics
	local source: MetricsOverrides = if overrides ~= nil then overrides else {}
	return {
		entry_speed = source.entry_speed or 40,
		exit_speed = source.exit_speed or 38,
		airborne = source.airborne or false,
		air_distance = source.air_distance or 0,
		lateral_error = source.lateral_error or 0,
		vertical_displacement = source.vertical_displacement or 0,
		reacquired = if source.reacquired ~= nil then source.reacquired else true,
		airtime_distance = source.airtime_distance or 0,
		target_airborne = source.target_airborne,
		target_air_distance = source.target_air_distance,
		target_vertical_displacement = source.target_vertical_displacement,
		target_reacquired = source.target_reacquired,
		target_airtime_distance = source.target_airtime_distance,
		target_left_offset = source.target_left_offset,
		target_right_offset = source.target_right_offset,
		target_lateral_band_changes = source.target_lateral_band_changes,
		target_entered = if source.target_entered ~= nil then source.target_entered else true,
		target_exited = if source.target_exited ~= nil then source.target_exited else true,
		target_progress = if source.target_progress ~= nil then source.target_progress else 1,
		target_reacquire_distance = source.target_reacquire_distance,
		target_reacquire_lateral_offset = source.target_reacquire_lateral_offset,
		target_peak_body_distance = source.target_peak_body_distance,
		target_exit_angular_speed = source.target_exit_angular_speed,
		target_exit_vertical_speed = source.target_exit_vertical_speed,
		target_touchdown_up_dot = source.target_touchdown_up_dot,
		target_touchdown_down_speed = source.target_touchdown_down_speed,
		target_apex_min_speed = source.target_apex_min_speed,
		lap_time = source.lap_time or 25,
		slowdown_ratio = source.slowdown_ratio or 1,
	}
end

local function makeRampJumpState(overrides: RampJumpOverrides?): SectorState
	local source: RampJumpOverrides = if overrides ~= nil then overrides else {}
	return {
		sector_id = source.sector_id or 2,
		mechanic = "RampJump",
		params = {
			ramp_angle = source.ramp_angle or 20,
			ramp_length = source.ramp_length or 12,
			gap_length = if source.gap_length ~= nil then source.gap_length else 8,
			landing_length = source.landing_length or 12,
		},
		pads = { ingress = "None", egress = "None" },
		version = 1,
	}
end

local function makeChicaneState(overrides: ChicaneOverrides?): SectorState
	local source: ChicaneOverrides = if overrides ~= nil then overrides else {}
	return {
		sector_id = source.sector_id or 2,
		mechanic = "Chicane",
		params = {
			amplitude = if source.amplitude ~= nil then source.amplitude else 8,
			transition_length = if source.transition_length ~= nil then source.transition_length else 15,
			corridor_width = source.corridor_width or 14,
		},
		pads = { ingress = "None", egress = "None" },
		version = 1,
	}
end

local function makeCrestDipState(overrides: CrestDipOverrides?): SectorState
	local source: CrestDipOverrides = if overrides ~= nil then overrides else {}
	return {
		sector_id = source.sector_id or 2,
		mechanic = "CrestDip",
		params = {
			height_or_depth = if source.height_or_depth ~= nil then source.height_or_depth else 8,
			radius = source.radius or 20,
			sector_length = source.sector_length or 30,
		},
		pads = { ingress = "None", egress = "None" },
		version = 1,
	}
end

local function makeRequest(): Request
	return {
		request_id = "test-001",
		raw_text = "add a ramp jump to sector 2",
		parsed = {
			sector_id = 2,
			mechanic = "RampJump",
			request_kind = "Mechanic",
			pad_side = nil,
			pad_value = nil,
		},
		qualifiers = {},
		timestamp = os.time(),
	}
end

-- ── RampJumpIntegrity unit tests ───────────────────────────────────────────────

local function testRampJump()
	local ok, hints

	-- pass: valid geometry + airborne + reacquired
	ok, hints = RampJumpIntegrity.evaluate(
		makeRampJumpState(),
		makeMetrics({ airborne = false, air_distance = 0, vertical_displacement = 2, reacquired = true })
	)
	T.expect("rampjump_pass", ok == true, "expected pass, got hints: " .. table.concat(hints, "; "))

	-- fail: gap_length below minimum
	ok, hints = RampJumpIntegrity.evaluate(
		makeRampJumpState({ gap_length = 1 }),
		makeMetrics({ airborne = true, air_distance = 10, reacquired = true })
	)
	T.expect(
		"rampjump_fail_gap",
		ok == false and #hints > 0,
		"expected fail on gap_length < " .. Constants.RAMPJUMP_MIN_GAP
	)

	-- fail: vertical displacement too small
	ok, hints = RampJumpIntegrity.evaluate(
		makeRampJumpState(),
		makeMetrics({ airborne = false, air_distance = 0, vertical_displacement = 0.2 })
	)
	T.expect(
		"rampjump_fail_vertical_displacement",
		ok == false and #hints > 0,
		"expected fail when vertical displacement is too small"
	)

	-- pass: short airtime is okay when the landing stays controlled
	ok, hints = RampJumpIntegrity.evaluate(
		makeRampJumpState(),
		makeMetrics({ airborne = true, air_distance = 1, vertical_displacement = 2, reacquired = true })
	)
	T.expect("rampjump_short_airtime_still_passes", ok == true, "expected controlled short airtime to pass")

	-- fail: no reacquisition
	ok, hints = RampJumpIntegrity.evaluate(
		makeRampJumpState(),
		makeMetrics({ airborne = true, air_distance = 3, vertical_displacement = 2, reacquired = false })
	)
	T.expect("rampjump_fail_no_reacquire", ok == false and #hints > 0, "expected fail when reacquired=false")

	-- RampJump should still demand a readable lift, even when it does not become a dramatic jump.
	ok, hints = RampJumpIntegrity.evaluateRuntime(makeMetrics({
		target_airborne = false,
		target_air_distance = 0,
		target_vertical_displacement = Constants.RAMPJUMP_MIN_VERTICAL_DISPLACEMENT - 0.1,
		target_reacquired = true,
	}))
	T.expect(
		"rampjump_fail_vertical_displacement_just_below_min",
		ok == false and #hints > 0,
		"expected fail at vertical displacement = MIN - epsilon"
	)

	ok, hints = RampJumpIntegrity.evaluateRuntime(makeMetrics({
		target_airborne = false,
		target_air_distance = 0,
		target_vertical_displacement = Constants.RAMPJUMP_MIN_VERTICAL_DISPLACEMENT
			+ Constants.RAMPJUMP_COMFORT_VERTICAL_MARGIN
			+ 0.1,
		target_reacquired = true,
		target_reacquire_distance = Constants.RAMPJUMP_REACQUIRE_MAX - Constants.RAMPJUMP_COMFORT_REACQUIRE_MARGIN - 1,
		target_exit_angular_speed = Constants.RAMPJUMP_COMFORT_EXIT_MAX_ANGULAR_SPEED - 0.25,
		target_exit_vertical_speed = Constants.RAMPJUMP_COMFORT_EXIT_MAX_VERTICAL_SPEED - 0.5,
	}))
	T.expect("rampjump_pass_vertical_displacement_with_margin", ok == true, "expected pass above the comfort floor")

	ok, hints = RampJumpIntegrity.evaluateRuntime({
		target_airborne = false,
		target_air_distance = 0,
		target_reacquired = true,
	})
	T.expect(
		"rampjump_fail_runtime_missing_vertical_displacement",
		ok == false and #hints > 0,
		"expected missing vertical displacement to fail instead of silently passing"
	)
end

-- ── ChicaneIntegrity unit tests ────────────────────────────────────────────────

local function testChicane()
	local ok, hints

	-- pass: valid geometry + target-sector lateral movement to both sides
	ok, hints = ChicaneIntegrity.evaluate(
		makeChicaneState(),
		makeMetrics({
			target_left_offset = 4,
			target_right_offset = 4,
			target_lateral_band_changes = 2,
		})
	)
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
	T.expect(
		"chicane_fail_amplitude",
		ok == false and #hints > 0,
		"expected fail when amplitude < " .. Constants.CHICANE_MIN_LATERAL_DISPLACEMENT
	)

	-- fail: curvature below minimum (amplitude=4, transition_length=200 → 0.02 < 0.05)
	ok, hints = ChicaneIntegrity.evaluate(
		makeChicaneState({ amplitude = 4, transition_length = 200 }),
		makeMetrics({
			target_left_offset = 4,
			target_right_offset = 4,
			target_lateral_band_changes = 2,
		})
	)
	T.expect(
		"chicane_fail_curvature",
		ok == false and #hints > 0,
		"expected fail when effective curvature < " .. Constants.CHICANE_MIN_CURVATURE
	)
end

-- ── CrestDipIntegrity unit tests ───────────────────────────────────────────────

local function testCrestDip()
	local ok, hints

	-- pass: valid params + runtime displacement
	ok, hints = CrestDipIntegrity.evaluate(makeCrestDipState(), makeMetrics({ vertical_displacement = 5 }))
	T.expect("crestdip_pass", ok == true, "expected pass, hints: " .. table.concat(hints, "; "))

	-- fail: height_or_depth below minimum
	ok, hints = CrestDipIntegrity.evaluate(
		makeCrestDipState({ height_or_depth = 1 }),
		makeMetrics({ vertical_displacement = 5 })
	)
	T.expect(
		"crestdip_fail_param",
		ok == false and #hints > 0,
		"expected fail when height_or_depth < " .. Constants.CRESTDIP_MIN_VERTICAL_DISPLACEMENT
	)

	-- fail: runtime vertical_displacement too small
	ok, hints = CrestDipIntegrity.evaluate(makeCrestDipState(), makeMetrics({ vertical_displacement = 0.5 }))
	T.expect(
		"crestdip_fail_runtime",
		ok == false and #hints > 0,
		"expected fail when runtime vertical_displacement < " .. Constants.CRESTDIP_MIN_VERTICAL_DISPLACEMENT
	)

	-- fail: no reacquisition
	ok, hints =
		CrestDipIntegrity.evaluate(makeCrestDipState(), makeMetrics({ vertical_displacement = 5, reacquired = false }))
	T.expect("crestdip_fail_no_reacquire", ok == false and #hints > 0, "expected fail when reacquired=false")

	-- fail: crest top crossed too slowly
	ok, hints = CrestDipIntegrity.evaluate(
		makeCrestDipState(),
		makeMetrics({
			vertical_displacement = 5,
			reacquired = true,
			target_apex_min_speed = Constants.CRESTDIP_APEX_MIN_SPEED - 1,
		})
	)
	T.expect(
		"crestdip_fail_apex_speed",
		ok == false and #hints > 0,
		"expected fail when crest apex speed is below minimum"
	)
end

-- ── LapEvaluator.evaluate unit tests ─────────────────────────────────────────

local function testEvaluator()
	local result, hints

	-- lap failure takes precedence over integrity
	result, hints = LapEvaluator.evaluate(
		{ type = "local_execution_failure", sector_id = 2 },
		makeRampJumpState(),
		makeMetrics({ airborne = true, air_distance = 10, vertical_displacement = 2, reacquired = true }),
		2
	)
	T.expect(
		"evaluator_lap_failure_takes_precedence",
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
	T.expect(
		"evaluator_upstream_failure_not_reclassified_before_target_entry",
		result.success == false
			and result.failure ~= nil
			and result.failure.type == "local_execution_failure"
			and result.failure.sector_id == 1,
		"expected upstream local_execution_failure to survive before target entry"
	)

	-- mechanic_integrity_failure — hints returned
	result, hints = LapEvaluator.evaluate(
		nil,
		makeRampJumpState({ gap_length = 1 }),
		makeMetrics({ airborne = true, air_distance = 10, vertical_displacement = 2, reacquired = true }),
		2
	)
	T.expect(
		"evaluator_integrity_fail_hints_returned",
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
		makeMetrics({ airborne = true, air_distance = 10, vertical_displacement = 2, reacquired = true }),
		2
	)
	T.expect(
		"evaluator_success",
		result.success == true and result.failure == nil and #hints == 0,
		"expected success=true for valid RampJump run"
	)

	-- downstream_failure reclassification: car failed in sector 5, target is sector 2
	result, hints = LapEvaluator.evaluate(
		{ type = "local_execution_failure", sector_id = 5 },
		makeRampJumpState(),
		makeMetrics({
			target_airborne = true,
			target_air_distance = 10,
			target_vertical_displacement = 2,
			target_reacquired = true,
		}),
		2
	)
	T.expect(
		"evaluator_downstream_reclassify",
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
		makeMetrics({
			target_airborne = false,
			target_air_distance = 0,
			target_vertical_displacement = 0,
			target_reacquired = true,
		}),
		2
	)
	T.expect(
		"evaluator_target_runtime_overrides_downstream",
		result.success == false
			and result.failure ~= nil
			and result.failure.type == "mechanic_integrity_failure"
			and result.failure.sector_id == 2
			and #hints > 0,
		"expected target mechanic_integrity_failure, got: " .. tostring(result.failure and result.failure.type)
	)

	result, hints = LapEvaluator.evaluate(
		{ type = "local_execution_failure", sector_id = 1 },
		makeRampJumpState(),
		makeMetrics({
			airborne = true,
			air_distance = 10,
			vertical_displacement = 2,
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
	T.expect(
		"evaluator_pre_target_failure_stays_non_target",
		result.success == false
			and result.failure ~= nil
			and result.failure.sector_id == 1
			and result.failure.type == "local_execution_failure",
		"expected non-target failure to remain non-target before target entry"
	)
end

-- ── LapEvaluator.buildFailurePacket unit tests ───────────────────────────────

local function testFailurePacket()
	local req = makeRequest()

	-- RampJump legal levers
	local rjState = makeRampJumpState()
	local rjFailure: FailureInfo = { type = "mechanic_integrity_failure", sector_id = 2 }
	local rjResult: RunResult = { success = false, failure = rjFailure, metrics = makeMetrics() }
	local packet = LapEvaluator.buildFailurePacket(req, rjState, 1, nil, rjResult, 2, { "gap too small" })

	local expectedRJ = LevelMappings.NUMERIC_LEVERS.RampJump
	local rjLeversMatch = #packet.legal_actions.numeric_levers == #expectedRJ
	if rjLeversMatch then
		for i, v in ipairs(expectedRJ) do
			if packet.legal_actions.numeric_levers[i] ~= v then
				rjLeversMatch = false
				break
			end
		end
	end
	T.expect(
		"failurepacket_legal_levers_rampjump",
		rjLeversMatch,
		"expected RampJump levers: " .. table.concat(expectedRJ, ",")
	)

	-- Chicane legal levers
	local chState = makeChicaneState()
	local chFailure: FailureInfo = { type = "mechanic_integrity_failure", sector_id = 2 }
	local chResult: RunResult = { success = false, failure = chFailure, metrics = makeMetrics() }
	local chPacket = LapEvaluator.buildFailurePacket(req, chState, 1, nil, chResult, 2, {})
	local expectedCh = LevelMappings.NUMERIC_LEVERS.Chicane
	local chLeversMatch = #chPacket.legal_actions.numeric_levers == #expectedCh
	T.expect(
		"failurepacket_legal_levers_chicane",
		chLeversMatch,
		"expected Chicane levers: " .. table.concat(expectedCh, ",")
	)

	-- CrestDip legal levers
	local cdState = makeCrestDipState()
	local cdFailure: FailureInfo = { type = "mechanic_integrity_failure", sector_id = 2 }
	local cdResult: RunResult = { success = false, failure = cdFailure, metrics = makeMetrics() }
	local cdPacket = LapEvaluator.buildFailurePacket(req, cdState, 1, nil, cdResult, 2, {})
	local expectedCd = LevelMappings.NUMERIC_LEVERS.CrestDip
	local cdLeversMatch = #cdPacket.legal_actions.numeric_levers == #expectedCd
	T.expect(
		"failurepacket_legal_levers_crestdip",
		cdLeversMatch,
		"expected CrestDip levers: " .. table.concat(expectedCd, ",")
	)

	-- pads always present
	local padsOk = packet.legal_actions.pads ~= nil
		and packet.legal_actions.pads[1] == "ingress"
		and packet.legal_actions.pads[2] == "egress"
	T.expect("failurepacket_pads_present", padsOk, "expected pads = { 'ingress', 'egress' }")

	-- hints are threaded through
	T.expect(
		"failurepacket_hints_threaded",
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
