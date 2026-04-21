local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))

type OrchestratorContext = Types.OrchestratorContext

local OrchestratorPromptBuilder = {}

local function encode(value): string
	return HttpService:JSONEncode(value)
end

function OrchestratorPromptBuilder.messages(context: OrchestratorContext): { { role: string, content: string } }
	return {
		{
			role = "system",
			content = table.concat({
				"You are the chief circuit designer for AutoTrack endurance mode.",
				"Return JSON only with no prose outside the JSON object.",
				"Goal: maximize spectacle and score while keeping lap slowdown within the endurance budget.",
				"You may target any editable sector, including overwriting an existing committed mechanic.",
				"You have a hard global attempt budget. Repairs within a chosen sector are handled elsewhere.",
				"Return either {\"sector_id\":number,\"mechanic\":\"RampJump|Chicane|CrestDip\",\"params_hint\":\"short natural-language hint\"}",
				"or {\"action\":\"begin_loop\"} when the track is balanced enough to start the live continuous loop.",
			}, "\n"),
		},
		{
			role = "user",
			content = table.concat({
				"Endurance orchestration context:",
				encode(context),
				"Pick the next sector and mechanic, or begin the loop.",
				"Keep params_hint short and descriptive. Use words like extreme, tall, tight, wide, steep, deep, gentle, long, short when helpful.",
			}, "\n"),
		},
	}
end

return OrchestratorPromptBuilder
