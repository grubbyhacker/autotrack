--!strict
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))

type OrchestratorContext = Types.OrchestratorContext

local OrchestratorPromptBuilder = {}

local function encode(
	value: OrchestratorContext | { shared: { Types.MemoryEntry }, orchestrator: { Types.MemoryEntry } }
): string
	return HttpService:JSONEncode(value)
end

local SUBMIT_DECISION_SCHEMA =
	[[{"action":"submit_request","sector_id":number,"mechanic":"RampJump|Chicane|CrestDip","params_hint":"short text","rationale":"short text","target_score_band":"low|medium|high|extreme","target_budget_tolerance":"low|medium|high","target_reliability":"conservative|balanced|risky","spectacle_priority":"low|medium|high","novelty_priority":"low|medium|high","replacement_intent":"open_slot_preferred|replace_if_gain|preserve_good_sector","desired_feel":"short text","constraints":["short constraint"]}]]
local MEMORY_NOTE_SCHEMA =
	[[{"author":"orchestrator","scope":"orchestrator","note":"short text","confidence":"low|medium|high","source_type":"observed_result|inferred_pattern|downstream_warning|explicit_policy","source_ref":"short ref"}]]

local function relevantMemory(
	context: OrchestratorContext
): { shared: { Types.MemoryEntry }, orchestrator: { Types.MemoryEntry } }
	local memory = context.memory
	return {
		shared = memory.shared,
		orchestrator = memory.orchestrator,
	}
end

function OrchestratorPromptBuilder.messages(context: OrchestratorContext): { { role: string, content: string } }
	return {
		{
			role = "system",
			content = table.concat({
				"You are the chief circuit designer for AutoTrack endurance mode.",
				"Return JSON only with no prose outside the JSON object.",
				"Goal: maximize realized committed score gain while keeping lap slowdown within the endurance budget.",
				"Formal objective: prefer candidates with strong projected score gain, strong realized yield from recent committed outcomes, novelty, and budget safety.",
				"Do not settle for minimum-valid safe sectors when the budget still has room for a more rewarding obstacle.",
				"Avoid repeating recently failed sector+mechanic+hint signatures when fresh alternatives exist.",
				"Treat attempt_history committed outcomes as ground truth for ranking. If a mechanic repeatedly commits at low score, deprioritize it.",
				"You may target any editable sector, including overwriting an existing committed mechanic.",
				"You have a hard global attempt budget. Repairs within a chosen sector are handled elsewhere.",
				"Return a full submit decision JSON object for the next build candidate.",
				"Submit decision schema: " .. SUBMIT_DECISION_SCHEMA,
				"You may also include an optional memory_note object using: " .. MEMORY_NOTE_SCHEMA,
				"Memory is advisory only. Current telemetry and budget state outrank remembered notes.",
				"If you include memory_note, it must stay in scope 'orchestrator' and capture only a short durable lesson.",
				"Every string field must stay short. constraints must be a short list of explicit downstream-preservation rules.",
				"Return either the full submit decision object",
				'or {"action":"begin_loop","rationale":"short reason"} when the track is balanced enough to start the live continuous loop.',
				"When proposing a candidate, make the object decision-complete for downstream proposal and repair agents.",
			}, "\n"),
		},
		{
			role = "user",
			content = table.concat({
				"Endurance orchestration context:",
				encode(context),
				"Relevant memory:",
				encode(relevantMemory(context)),
				'Pick the next sector and mechanic with action="submit_request", or begin the loop.',
				"Keep params_hint and desired_feel short and descriptive. Use words like extreme, tall, tight, wide, steep, deep, gentle, long, short when helpful.",
				"Use attempt_history, mechanic_repeat_pressure, sector_attempt_counts, track_intent, and memory directly when ranking candidates.",
			}, "\n"),
		},
	}
end

return OrchestratorPromptBuilder
