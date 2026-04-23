local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local T = require(script.Parent.TestUtils)
local JobRunner = require(script.Parent.JobRunner)
local RampJumpIntegrity = require(script.Parent.Parent.Integrity.RampJumpIntegrity)
local RampJumpPath = require(script.Parent.Parent.Mechanics.RampJumpPath)
local MetricCollector = require(script.Parent.Parent.Verifier.MetricCollector)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)
local PromptBuilder = require(script.Parent.Parent.Agent.PromptBuilder)
local LLMAdapter = require(script.Parent.Parent.Agent.LLMAdapter)

type Request = Types.Request

local TestPhase27 = {}

local function makeRequest(scoreBand: string): Request
	return {
		request_id = "phase27-retention",
		raw_text = "add ramp jump sector 3",
		parsed = {
			sector_id = 3,
			mechanic = "RampJump",
			request_kind = "Mechanic",
			pad_side = nil,
			pad_value = nil,
		},
		qualifiers = { "extreme" },
		origin = "endurance",
		design_intent = {
			sector_id = 3,
			mechanic = "RampJump",
			params_hint = "extreme tall",
			rationale = "phase27 test",
			target_score_band = scoreBand,
			target_budget_tolerance = "medium",
			target_reliability = "balanced",
			spectacle_priority = "high",
			novelty_priority = "medium",
			replacement_intent = "replace_if_gain",
			desired_feel = "high risk",
			constraints = { "stay in sector 3" },
		},
		memory_context = nil,
		timestamp = os.time(),
	}
end

local function emptyMemory()
	return {
		shared = {},
		orchestrator = {},
		proposal = {},
		repair = {},
	}
end

local function makeRunMetrics(overrides)
	local metrics = {
		entry_speed = 34,
		exit_speed = 0,
		airborne = false,
		air_distance = 0,
		lateral_error = 0,
		vertical_displacement = 6,
		reacquired = false,
		airtime_distance = 0,
		target_airborne = false,
		target_air_distance = 0,
		target_vertical_displacement = 6,
		target_reacquired = false,
		target_airtime_distance = 0,
		target_left_offset = 0,
		target_right_offset = 0,
		target_lateral_band_changes = 0,
		target_entered = true,
		target_exited = false,
		target_progress = 0.4,
		target_reacquire_distance = 0,
		target_peak_body_distance = 0,
		target_exit_angular_speed = 0,
		target_exit_vertical_speed = 0,
		target_touchdown_up_dot = 0,
		target_touchdown_down_speed = 0,
		lap_time = 0,
		slowdown_ratio = 1.2,
	}
	for key, value in pairs(overrides or {}) do
		metrics[key] = value
	end
	return metrics
end

local function makeRepairPacket(request: Request, state, failureType: string, failureDetail: string, hints: { string }, metrics)
	return {
		request = request,
		sector_state = state,
		attempt_index = 1,
		last_action = nil,
		run_result = {
			success = false,
			failure = {
				type = failureType,
				sector_id = state.sector_id,
				detail = failureDetail,
			},
			metrics = metrics,
			score = nil,
		},
		diagnostics = {
			failure_sector = state.sector_id,
			hints = hints,
			failure_type = failureType,
			failure_detail = failureDetail,
			target_entry_speed = metrics.entry_speed,
			target_exit_speed = metrics.exit_speed,
			target_reacquired = metrics.target_reacquired,
			target_airtime_distance = metrics.target_airtime_distance,
			target_apex_min_speed = metrics.target_apex_min_speed,
		},
		legal_actions = {
			numeric_levers = { "ramp_angle", "ramp_length", "gap_length", "landing_length" },
			pads = { "ingress", "egress" },
		},
		design_intent = request.design_intent,
		memory_context = request.memory_context,
	}
end

local function lipSlope(points: { Vector3 }): number
	if #points < 2 then
		return 0
	end
	local a = points[#points - 1]
	local b = points[#points]
	local dz = math.max(1e-4, b.Z - a.Z)
	return (b.Y - a.Y) / dz
end

function TestPhase27.run()
	local oldProfileMode = workspace:GetAttribute("AutoTrack_RampJumpProfileMode")

		local ok, err = pcall(function()
		local requestHigh = makeRequest("high")
		local rejected, requiredRejected = JobRunner._evaluateRampJumpRepairScoreRetention(
			requestHigh,
			1,
			12,
			{ score = { total = 8.0 } }
		)
		T.expect(
			"phase27_rampjump_repair_score_retention_rejects_neutralized_success",
			rejected == false and requiredRejected >= 8.39,
			HttpService:JSONEncode({ passed = rejected, required = requiredRejected })
		)

		local accepted, requiredAccepted = JobRunner._evaluateRampJumpRepairScoreRetention(
			requestHigh,
			2,
			12,
			{ score = { total = 8.6 } }
		)
		T.expect(
			"phase27_rampjump_repair_score_retention_accepts_high_enough_score",
			accepted == true and requiredAccepted >= 8.39,
			HttpService:JSONEncode({ passed = accepted, required = requiredAccepted })
		)

		local attemptZeroPass = JobRunner._evaluateRampJumpRepairScoreRetention(
			requestHigh,
			0,
			12,
			{ score = { total = 2.0 } }
		)
		T.expect("phase27_rampjump_retention_gate_skips_initial_attempt", attemptZeroPass == true, tostring(attemptZeroPass))

		local challengeProbeResult = {
			score = {
				total = 8.2,
				budget_used = 0.35,
				over_budget = false,
			},
		}
		local highEnergyRampState = {
			sector_id = 3,
			mechanic = "RampJump",
			params = {
				ramp_angle = 18,
				ramp_length = 48,
				gap_length = 12,
				landing_length = 40,
			},
			pads = { ingress = "Boost50", egress = "Brake25" },
			version = 2,
		}
		local repairedChallengeAllowed, repairedChallengeReason = JobRunner._shouldRunChallengeUp(
			requestHigh,
			challengeProbeResult,
			true,
			1,
			highEnergyRampState
		)
		T.expect(
			"phase27_rampjump_challenge_up_skips_repaired_success",
			repairedChallengeAllowed == false and repairedChallengeReason == "rampjump_repaired_success",
			tostring(repairedChallengeReason)
		)

		local highEnergyChallengeAllowed, highEnergyChallengeReason = JobRunner._shouldRunChallengeUp(
			requestHigh,
			challengeProbeResult,
			true,
			0,
			highEnergyRampState
		)
		T.expect(
			"phase27_rampjump_challenge_up_skips_high_energy_baseline",
			highEnergyChallengeAllowed == false and highEnergyChallengeReason == "rampjump_already_high_energy",
			tostring(highEnergyChallengeReason)
		)

		local uprightHardLandingOk, uprightHints = RampJumpIntegrity.evaluateRuntime({
			target_vertical_displacement = 4.0,
			target_reacquired = true,
			target_reacquire_distance = 8.0,
			target_exit_angular_speed = 6.0,
			target_exit_vertical_speed = 20.0,
			target_touchdown_up_dot = 0.86,
			target_touchdown_down_speed = 14.0,
		})
		T.expect(
			"phase27_rampjump_upright_hard_landing_path_allows_higher_exit_energy",
			uprightHardLandingOk == true,
			table.concat(uprightHints or {}, " | ")
		)

		local notUprightOk, notUprightHints = RampJumpIntegrity.evaluateRuntime({
			target_vertical_displacement = 4.0,
			target_reacquired = true,
			target_reacquire_distance = 8.0,
			target_exit_angular_speed = 6.0,
			target_exit_vertical_speed = 20.0,
			target_touchdown_up_dot = 0.60,
			target_touchdown_down_speed = 14.0,
		})
		T.expect(
			"phase27_rampjump_hard_landing_requires_upright_touchdown",
			notUprightOk == false,
			table.concat(notUprightHints or {}, " | ")
		)

		local uprightReacquireBonusOk, uprightReacquireBonusHints = RampJumpIntegrity.evaluateRuntime({
			target_vertical_displacement = 4.0,
			target_reacquired = true,
			target_reacquire_distance = 14.5,
			target_exit_angular_speed = 4.0,
			target_exit_vertical_speed = 12.0,
			target_touchdown_up_dot = 0.90,
			target_touchdown_down_speed = 14.0,
		})
		T.expect(
			"phase27_rampjump_upright_reacquire_bonus_allows_borderline_distance",
			uprightReacquireBonusOk == true,
			table.concat(uprightReacquireBonusHints or {}, " | ")
		)

		local notUprightReacquireBonusOk, notUprightReacquireBonusHints = RampJumpIntegrity.evaluateRuntime({
			target_vertical_displacement = 4.0,
			target_reacquired = true,
			target_reacquire_distance = 14.5,
			target_exit_angular_speed = 4.0,
			target_exit_vertical_speed = 12.0,
			target_touchdown_up_dot = 0.60,
			target_touchdown_down_speed = 14.0,
		})
		T.expect(
			"phase27_rampjump_reacquire_bonus_requires_upright_touchdown",
			notUprightReacquireBonusOk == false,
			table.concat(notUprightReacquireBonusHints or {}, " | ")
		)

		local corridorPassOk, corridorPassHints = RampJumpIntegrity.evaluateRuntime({
			target_vertical_displacement = 4.0,
			target_reacquired = true,
			target_reacquire_distance = 26.0,
			target_reacquire_lateral_offset = Constants.TRACK_WIDTH * 0.45,
			target_exit_angular_speed = 4.0,
			target_exit_vertical_speed = 10.0,
		})
		T.expect(
			"phase27_rampjump_reacquire_corridor_allows_long_distance_when_centered",
			corridorPassOk == true,
			table.concat(corridorPassHints or {}, " | ")
		)

		local corridorFailOk, corridorFailHints = RampJumpIntegrity.evaluateRuntime({
			target_vertical_displacement = 4.0,
			target_reacquired = true,
			target_reacquire_distance = 26.0,
			target_reacquire_lateral_offset = Constants.TRACK_WIDTH * 0.65,
			target_exit_angular_speed = 4.0,
			target_exit_vertical_speed = 10.0,
		})
		T.expect(
			"phase27_rampjump_reacquire_corridor_rejects_far_lateral_rejoin",
			corridorFailOk == false
				and string.find(table.concat(corridorFailHints or {}, " | "), "centerline corridor", 1, true) ~= nil,
			table.concat(corridorFailHints or {}, " | ")
		)

		local linearProfile = RampJumpPath.buildProfile(14, 36, 10, 24, "linear_blend")
		local curvedProfile = RampJumpPath.buildProfile(14, 36, 10, 24, "curved_lift")
		T.expect(
			"phase27_rampjump_profiles_preserve_sector_completeness",
			math.abs(linearProfile.landingPoints[#linearProfile.landingPoints].Z - Constants.STRAIGHT_LENGTH) <= 0.01
				and math.abs(curvedProfile.landingPoints[#curvedProfile.landingPoints].Z - Constants.STRAIGHT_LENGTH) <= 0.01
				and linearProfile.entryRunout >= 0
				and linearProfile.exitRunout >= 0
				and curvedProfile.entryRunout >= 0
				and curvedProfile.exitRunout >= 0,
			HttpService:JSONEncode({
				linear_end = linearProfile.landingPoints[#linearProfile.landingPoints].Z,
				curved_end = curvedProfile.landingPoints[#curvedProfile.landingPoints].Z,
				linear_entry = linearProfile.entryRunout,
				linear_exit = linearProfile.exitRunout,
				curved_entry = curvedProfile.entryRunout,
				curved_exit = curvedProfile.exitRunout,
			})
		)

		T.expect(
			"phase27_rampjump_curved_lift_increases_lip_slope",
			lipSlope(curvedProfile.rampPoints) > lipSlope(linearProfile.rampPoints),
			HttpService:JSONEncode({
				linear_lip_slope = lipSlope(linearProfile.rampPoints),
				curved_lip_slope = lipSlope(curvedProfile.rampPoints),
			})
		)

		workspace:SetAttribute("AutoTrack_RampJumpProfileMode", 1)
		local attrCurved = RampJumpPath.buildProfile(12, 34, 8, 26)
		workspace:SetAttribute("AutoTrack_RampJumpProfileMode", 0)
		local attrLinear = RampJumpPath.buildProfile(12, 34, 8, 26)
		T.expect(
			"phase27_rampjump_profile_mode_attr_switches_generation_mode",
			attrCurved.profile_mode == "curved_lift" and attrLinear.profile_mode == "linear_blend",
			HttpService:JSONEncode({ curved = attrCurved.profile_mode, linear = attrLinear.profile_mode })
		)

		local rampSurfaceState = {
			sector_id = 3,
			mechanic = "RampJump",
			params = {
				ramp_angle = 14,
				ramp_length = 40,
				gap_length = 10,
				landing_length = 40,
			},
			pads = { ingress = "None", egress = "None" },
			version = 1,
		}
		local rampSurfaceActive = VerifierController._isRampJumpGroundedSurfaceActive(rampSurfaceState, 0.45, false)
		local rampSurfaceInactive = VerifierController._isRampJumpGroundedSurfaceActive(rampSurfaceState, 0.05, false)
		local dampedAngular = VerifierController._resolveRampJumpSurfaceAngularVelocity(
			true,
			1 / 60,
			Vector3.new(6.0, 4.5, 4.5)
		)
		local dampedLinear = VerifierController._dampRampJumpGroundedLateralVelocity(
			true,
			1 / 60,
			Vector3.new(20, 0, 40),
			Vector3.zAxis
		)
		local forgivenContainment = VerifierController._resolveRampJumpContainmentDistance(
			true,
			true,
			false,
			0.9,
			Constants.TRACK_WIDTH * 0.25,
			Constants.TRACK_WIDTH * 1.4
		)
		local strictContainment = VerifierController._resolveRampJumpContainmentDistance(
			true,
			true,
			false,
			0.2,
			Constants.TRACK_WIDTH * 0.25,
			Constants.TRACK_WIDTH * 1.4
		)
		T.expect(
			"phase27_rampjump_surface_stabilization_window_and_damping",
			rampSurfaceActive == true
				and rampSurfaceInactive == false
				and dampedAngular.X < 6.0
				and dampedAngular.Y < 4.5
				and dampedAngular.Z < 4.5
				and math.abs(dampedLinear.X) < 20
				and forgivenContainment <= Constants.TRACK_WIDTH * 0.3
				and strictContainment >= Constants.TRACK_WIDTH,
			HttpService:JSONEncode({
				active = rampSurfaceActive,
				inactive = rampSurfaceInactive,
				angular = { x = dampedAngular.X, y = dampedAngular.Y, z = dampedAngular.Z },
				linear = { x = dampedLinear.X, y = dampedLinear.Y, z = dampedLinear.Z },
				forgiven_containment = forgivenContainment,
				strict_containment = strictContainment,
			})
		)

			local repairRequest = makeRequest("high")
			repairRequest.memory_context = emptyMemory()
			local currentState = {
				sector_id = 3,
				mechanic = "RampJump",
				params = {
					ramp_angle = 14,
					ramp_length = 34,
					gap_length = 10,
					landing_length = 24,
				},
				pads = { ingress = "None", egress = "None" },
				version = 1,
			}
			local packet = makeRepairPacket(
				repairRequest,
				currentState,
				"local_execution_failure",
				"no_progress",
				{ "no_progress", "speed bled off climbing the ramp" },
				makeRunMetrics({ target_apex_min_speed = 9 })
			)
			local history = {
				{
					attempt_index = 0,
					action = nil,
					proposed_state = {
						sector_id = 3,
						mechanic = "RampJump",
						params = {
							ramp_angle = 16,
							ramp_length = 40,
							gap_length = 12,
							landing_length = 22,
						},
						pads = { ingress = "None", egress = "None" },
						version = 0,
					},
					result = packet.run_result,
					hints = {},
					memory_note = nil,
				},
			}
			local repairMessages = PromptBuilder.repairMessages(repairRequest, history, packet, repairRequest.design_intent)
			local repairTail = repairMessages[#repairMessages].content
			T.expect(
				"phase27_repair_prompt_avoids_blanket_make_easier_language",
				string.find(repairTail, "fix the specific failure while preserving scoreable challenge", 1, true) ~= nil
					and string.find(repairTail, "make the obstacle easier", 1, true) == nil,
				repairTail
			)

			LLMAdapter.setProvider("phase27-rampjump-guard", {
				propose = function()
					return HttpService:JSONEncode(currentState)
				end,
				repair = function()
					return HttpService:JSONEncode({
						newState = {
							sector_id = 3,
							mechanic = "RampJump",
							params = {
								ramp_angle = 3,
								ramp_length = 52,
								gap_length = 18,
								landing_length = 72,
							},
							pads = {
								ingress = "Brake50",
								egress = "Brake50",
							},
							version = 2,
						},
						explanation = "flattening jump to make it safer",
					})
				end,
				orchestrate = function()
					return HttpService:JSONEncode({ action = "begin_loop", rationale = "test only" })
				end,
			})

			local _, guardedState, _, _, guardErr = LLMAdapter.repair(packet, history, repairRequest.design_intent)
			T.expect(
				"phase27_rampjump_repair_guardrails_prevent_no_progress_flattening",
				guardErr == nil
					and guardedState ~= nil
					and string.find(tostring(guardedState.pads.ingress), "Boost", 1, true) == 1
					and guardedState.params.ramp_length <= currentState.params.ramp_length
					and guardedState.params.gap_length <= currentState.params.gap_length
					and guardedState.params.ramp_angle >= 13
					and guardedState.pads.egress ~= "Brake50",
				HttpService:JSONEncode({
					err = guardErr,
					guarded = guardedState,
				})
			)

			local instabilityPacket = makeRepairPacket(
				repairRequest,
				{
					sector_id = 3,
					mechanic = "RampJump",
					params = {
						ramp_angle = 14,
						ramp_length = 41,
						gap_length = 11,
						landing_length = 60,
					},
					pads = { ingress = "Boost50", egress = "Brake25" },
					version = 7,
				},
				"local_execution_failure",
				"tumble",
				{ "tumble", "body_off_track" },
				makeRunMetrics({
					target_progress = 0.0,
					target_reacquired = false,
				})
			)
			local instabilityHistory = {
				{
					attempt_index = 5,
					action = nil,
					proposed_state = {
						sector_id = 3,
						mechanic = "RampJump",
						params = {
							ramp_angle = 14,
							ramp_length = 41,
							gap_length = 11,
							landing_length = 60,
						},
						pads = { ingress = "Boost50", egress = "Brake25" },
						version = 6,
					},
					result = {
						success = false,
						failure = { type = "local_execution_failure", sector_id = 3, detail = "body_off_track" },
						metrics = makeRunMetrics({ target_progress = 0.0, target_reacquired = false }),
						score = nil,
					},
					hints = { "body_off_track" },
					memory_note = nil,
				},
				{
					attempt_index = 6,
					action = nil,
					proposed_state = {
						sector_id = 3,
						mechanic = "RampJump",
						params = {
							ramp_angle = 14,
							ramp_length = 41,
							gap_length = 11,
							landing_length = 60,
						},
						pads = { ingress = "Boost50", egress = "Brake25" },
						version = 7,
					},
					result = {
						success = false,
						failure = { type = "local_execution_failure", sector_id = 3, detail = "tumble" },
						metrics = makeRunMetrics({ target_progress = 0.0, target_reacquired = false }),
						score = nil,
					},
					hints = { "tumble" },
					memory_note = nil,
				},
			}
			table.insert(instabilityHistory, {
				attempt_index = 7,
				action = nil,
				proposed_state = instabilityPacket.sector_state,
				result = instabilityPacket.run_result,
				hints = instabilityPacket.diagnostics.hints,
				memory_note = nil,
			})

			LLMAdapter.setProvider("phase27-rampjump-loop-escape", {
				propose = function()
					return HttpService:JSONEncode(instabilityPacket.sector_state)
				end,
				repair = function()
					return HttpService:JSONEncode({
						newState = {
							sector_id = 3,
							mechanic = "RampJump",
							params = {
								ramp_angle = 14,
								ramp_length = 41,
								gap_length = 11,
								landing_length = 60,
							},
							pads = {
								ingress = "Boost50",
								egress = "Brake25",
							},
							version = 8,
						},
						explanation = "retrying same high-energy setup",
					})
				end,
				orchestrate = function()
					return HttpService:JSONEncode({ action = "begin_loop", rationale = "test only" })
				end,
			})
			local _, escapedState, _, _, escapeErr = LLMAdapter.repair(
				instabilityPacket,
				instabilityHistory,
				repairRequest.design_intent
			)
			T.expect(
				"phase27_rampjump_repair_guardrails_escape_repeat_zero_progress_instability",
				escapeErr == nil
					and escapedState ~= nil
					and escapedState.pads.ingress ~= "Boost50"
					and escapedState.params.ramp_angle <= 13
					and escapedState.params.ramp_length <= 39
					and escapedState.params.gap_length <= 10
					and escapedState.params.landing_length >= 62,
				HttpService:JSONEncode({
					err = escapeErr,
					state = escapedState,
				})
			)

			MetricCollector.reset(0, 3)
			MetricCollector.onTargetTouchdown(0.82, 16)
		local touchdownMetrics = MetricCollector.finalise(3, 10, 10)
		T.expect(
			"phase27_touchdown_metrics_exposed_in_runmetrics",
			type(touchdownMetrics.target_touchdown_up_dot) == "number"
				and type(touchdownMetrics.target_touchdown_down_speed) == "number"
				and (touchdownMetrics.target_touchdown_up_dot or 0) >= 0.82
				and (touchdownMetrics.target_touchdown_down_speed or 0) >= 16,
			HttpService:JSONEncode({
				up_dot = touchdownMetrics.target_touchdown_up_dot,
				down_speed = touchdownMetrics.target_touchdown_down_speed,
			})
		)
	end)

	workspace:SetAttribute("AutoTrack_RampJumpProfileMode", oldProfileMode)
	LLMAdapter.useMockProvider()
	if not ok then
		error(err)
	end
end

return TestPhase27
