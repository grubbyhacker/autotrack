local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ContractBuilders = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("ContractBuilders"))
local TestFactories = require(script.Parent.TestFactories)
local T = require(script.Parent.TestUtils)

local TestPhase36 = {}

function TestPhase36.run()
	local mechanicRequest = ContractBuilders.playerMechanicRequest(
		"phase36-mechanic",
		"add a jump in sector 7",
		7,
		"RampJump",
		{ "extreme" },
		123
	)
	T.expect(
		"phase36_builder_player_mechanic_request",
		mechanicRequest.origin == "player"
			and mechanicRequest.parsed.request_kind == "Mechanic"
			and mechanicRequest.parsed.sector_id == 7
			and mechanicRequest.parsed.mechanic == "RampJump"
			and mechanicRequest.parsed.pad_side == nil
			and mechanicRequest.qualifiers[1] == "extreme"
			and mechanicRequest.timestamp == 123,
		HttpService:JSONEncode(mechanicRequest)
	)

	local padRequest =
		ContractBuilders.playerPadRequest("phase36-pad", "add exit boost pad to sector 3", 3, "egress", "Boost25", 456)
	T.expect(
		"phase36_builder_player_pad_request",
		padRequest.origin == "player"
			and padRequest.parsed.request_kind == "Pad"
			and padRequest.parsed.mechanic == nil
			and padRequest.parsed.pad_side == "egress"
			and padRequest.parsed.pad_value == "Boost25"
			and padRequest.timestamp == 456,
		HttpService:JSONEncode(padRequest)
	)

	local sourceConstraints = { "preserve downstream stability" }
	local intent = ContractBuilders.designIntent({
		sector_id = 4,
		mechanic = "Chicane",
		params_hint = "tight wide",
		constraints = sourceConstraints,
	})
	sourceConstraints[1] = "mutated after build"
	T.expect(
		"phase36_builder_design_intent_defaults_and_clones",
		intent.sector_id == 4
			and intent.mechanic == "Chicane"
			and intent.target_score_band == "high"
			and intent.target_reliability == "balanced"
			and intent.constraints[1] == "preserve downstream stability",
		HttpService:JSONEncode(intent)
	)

	local submitDecision = ContractBuilders.submitDecision({
		sector_id = 8,
		mechanic = "CrestDip",
		params_hint = "deep crest",
		target_score_band = "extreme",
	})
	T.expect(
		"phase36_builder_submit_decision_is_tagged_union",
		submitDecision.action == "submit_request"
			and submitDecision.sector_id == 8
			and submitDecision.mechanic == "CrestDip"
			and submitDecision.target_score_band == "extreme",
		HttpService:JSONEncode(submitDecision)
	)

	local numericAction = ContractBuilders.setNumericLever("gap_length", 12)
	local padAction = ContractBuilders.setPad("ingress", "Brake10")
	T.expect(
		"phase36_builder_agent_actions",
		numericAction.type == "SetNumericLever"
			and numericAction.lever == "gap_length"
			and numericAction.value == 12
			and padAction.type == "SetPad"
			and padAction.pad == "ingress"
			and padAction.value == "Brake10",
		HttpService:JSONEncode({ numeric = numericAction, pad = padAction })
	)

	local context = TestFactories.orchestratorContext({
		budget = { used = 0.42, over_budget = false },
		sector_states = {
			[2] = { mechanic = "RampJump", params = {}, score = 20 },
		},
	})
	T.expect(
		"phase36_test_factory_context_is_complete_by_default",
		context.budget.used == 0.42
			and context.memory ~= nil
			and context.memory.shared ~= nil
			and context.attempt_history ~= nil
			and context.track_intent ~= nil
			and context.sector_states[2].mechanic == "RampJump",
		HttpService:JSONEncode(context)
	)
end

return TestPhase36
