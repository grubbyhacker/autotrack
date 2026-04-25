--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ContractBuilders = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("ContractBuilders"))
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local ActionValidator = require(script.Parent.Parent.Agent.ActionValidator)
local LLMTraceJournal = require(script.Parent.Parent.Agent.LLMTraceJournal)
local SectorSerializer = require(script.Parent.Parent.Track.SectorSerializer)
local TestFactories = require(script.Parent.TestFactories)
local T = require(script.Parent.TestUtils)

type JsonArray = Types.JsonArray
type JsonObject = Types.JsonObject
type JsonValue = Types.JsonValue
type OrchestratorSectorSnapshot = Types.OrchestratorSectorSnapshot
type SectorState = Types.SectorState

local TestPhase37 = {}

local function asObject(value: JsonValue?): JsonObject?
	if type(value) == "table" then
		return value :: JsonObject
	end
	return nil
end

local function asArray(value: JsonValue?): JsonArray?
	if type(value) == "table" then
		return value :: JsonArray
	end
	return nil
end

local function testTraceJournalJsonExport()
	LLMTraceJournal.clearForTests()

	local cyclic: { [string]: unknown } = {}
	cyclic.self = cyclic

	LLMTraceJournal.beginRun({
		owner = "phase37",
		mode = "unit",
		job_id = "job-phase37",
		meta_vector = Vector3.new(1, 2, 3),
	})
	LLMTraceJournal.append({
		role = "proposal",
		direction = "prompt",
		provider = "phase37-provider",
		model = "phase37-model",
		kind = "propose",
		payload = {
			position = Vector3.new(4, 5, 6),
			cycle = cyclic,
			nested = {
				ok = true,
			},
		},
	})
	LLMTraceJournal.finishRun({
		outcome = "ok",
		color = Color3.new(0.25, 0.5, 0.75),
	})

	local exported = LLMTraceJournal.exportLatestRun()
	local events = if exported ~= nil then asArray(exported.events) else nil
	local firstEvent = if events ~= nil then asObject(events[1]) else nil
	local payload = if firstEvent ~= nil then asObject(firstEvent.payload) else nil
	local position = if payload ~= nil then asObject(payload.position) else nil
	local cycle = if payload ~= nil then asObject(payload.cycle) else nil
	local summary = if exported ~= nil then asObject(exported.summary) else nil
	local color = if summary ~= nil then asObject(summary.color) else nil

	T.expect(
		"phase37_trace_export_is_json_object",
		exported ~= nil and exported.owner == "phase37" and exported.event_count == 1 and events ~= nil and #events == 1,
		HttpService:JSONEncode(exported or {})
	)
	T.expect(
		"phase37_trace_sanitizes_runtime_values",
		position ~= nil
			and position.__type == "Vector3"
			and position.x == 4
			and cycle ~= nil
			and cycle.self == "<cycle>"
			and color ~= nil
			and color.__type == "Color3",
		HttpService:JSONEncode(exported or {})
	)
end

local function testSectorSerializerJsonShape()
	local state: SectorState = {
		sector_id = 3,
		mechanic = "RampJump",
		params = {
			ramp_angle = 12,
			ramp_length = 24,
			gap_length = 8,
			landing_length = 26,
		},
		pads = {
			ingress = "Boost10",
			egress = "Brake5",
		},
		version = 7,
	}

	local serialized = SectorSerializer.toTable(state)
	local params = asObject(serialized.params)
	local pads = asObject(serialized.pads)
	T.expect(
		"phase37_sector_serializer_returns_json_contract",
		serialized.sector_id == 3
			and serialized.mechanic == "RampJump"
			and serialized.version == 7
			and params ~= nil
			and params.ramp_angle == 12
			and pads ~= nil
			and pads.ingress == "Boost10"
			and pads.egress == "Brake5",
		HttpService:JSONEncode(serialized)
	)
end

local function testFactoriesAndActionBuilders()
	local sectorStates: { [number]: OrchestratorSectorSnapshot } = {
		[4] = { mechanic = "Chicane", params = { amplitude = 8 }, score = 22 },
	}
	local context = TestFactories.orchestratorContext({
		sector_states = sectorStates,
		budget = { used = 0.31, over_budget = false },
	})
	local decision = TestFactories.submitDecision({
		sector_id = 4,
		mechanic = "Chicane",
		params_hint = "tight wide",
		target_score_band = "extreme",
	})
	local numericAction = ContractBuilders.setNumericLever("amplitude", 9)
	local padAction = ContractBuilders.setPad("ingress", "Brake25")
	local numericOk = ActionValidator.validateAction(numericAction, "Chicane")
	local padOk = ActionValidator.validateAction(padAction, "Chicane")

	T.expect(
		"phase37_test_factories_are_typed_and_complete",
		context.budget.used == 0.31
			and context.memory.shared ~= nil
			and context.sector_states[4].mechanic == "Chicane"
			and decision.action == "submit_request"
			and decision.target_score_band == "extreme",
		HttpService:JSONEncode({ context = context, decision = decision })
	)
	T.expect(
		"phase37_action_builders_validate",
		numericOk == true and padOk == true and numericAction.type == "SetNumericLever" and padAction.type == "SetPad",
		HttpService:JSONEncode({ numeric = numericAction, pad = padAction })
	)
end

function TestPhase37.run()
	testTraceJournalJsonExport()
	testSectorSerializerJsonShape()
	testFactoriesAndActionBuilders()
end

return TestPhase37
