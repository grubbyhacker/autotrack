local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))

type OrchestratorContext = Types.OrchestratorContext

local OrchestratorPromptBuilder = {}

local function encode(value): string
	return HttpService:JSONEncode(value)
end

local DESIGN_INTENT_SCHEMA = [[{"sector_id":number,"mechanic":"RampJump|Chicane|CrestDip","params_hint":"short text","rationale":"short text","target_score_band":"low|medium|high|extreme","target_budget_tolerance":"low|medium|high","target_reliability":"conservative|balanced|risky","spectacle_priority":"low|medium|high","novelty_priority":"low|medium|high","replacement_intent":"open_slot_preferred|replace_if_gain|preserve_good_sector","desired_feel":"short text","constraints":["short constraint"]}]]

function OrchestratorPromptBuilder.messages(context: OrchestratorContext): { { role: string, content: string } }
	return {
		{
			role = "system",
			content = table.concat({
				"You are the chief circuit designer for AutoTrack endurance mode.",
				"Return JSON only with no prose outside the JSON object.",
				"Goal: maximize spectacle and score while keeping lap slowdown within the endurance budget.",
				"Formal objective: prefer candidates with strong projected score gain, sustainable reliability, novelty, and low repair complexity.",
				"Avoid repeating recently failed sector+mechanic+hint signatures when fresh alternatives exist.",
				"You may target any editable sector, including overwriting an existing committed mechanic.",
				"You have a hard global attempt budget. Repairs within a chosen sector are handled elsewhere.",
				"Return a full shared DesignIntent JSON object for the next build candidate.",
				"DesignIntent schema: " .. DESIGN_INTENT_SCHEMA,
				"Every string field must stay short. constraints must be a short list of explicit downstream-preservation rules.",
				"Return either the full DesignIntent object",
				"or {\"action\":\"begin_loop\",\"rationale\":\"short reason\"} when the track is balanced enough to start the live continuous loop.",
				"When proposing a candidate, make the object decision-complete for downstream proposal and repair agents.",
			}, "\n"),
		},
		{
			role = "user",
			content = table.concat({
				"Endurance orchestration context:",
				encode(context),
				"Pick the next sector and mechanic, or begin the loop.",
				"Keep params_hint and desired_feel short and descriptive. Use words like extreme, tall, tight, wide, steep, deep, gentle, long, short when helpful.",
				"Use attempt_history, mechanic_repeat_pressure, sector_attempt_counts, and track_intent directly when ranking candidates.",
			}, "\n"),
		},
	}
end

return OrchestratorPromptBuilder
