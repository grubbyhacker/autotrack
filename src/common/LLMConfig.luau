-- LLMConfig.luau
-- Central configuration for LLM provider selection.
-- LLM usage is disabled by default; toggle via UIState or workspace attributes at boot.

local LLMConfig = {}

-- Ordered model list. "heuristic" is always first and means MinimalProposer.
-- integerLevers: when true, float lever values from the LLM are rounded to integers.
LLMConfig.MODELS = {
	{ id = "heuristic",                    displayName = "Heuristic",     integerLevers = true  },
	{ id = "google/gemma-3-4b-it",         displayName = "Gemma 3 4B",    integerLevers = true  },
	{ id = "google/gemma-4-31b-it:free",   displayName = "Gemma 4 31B",   integerLevers = true  },
	{ id = "qwen/qwen-turbo",              displayName = "Qwen Turbo",    integerLevers = true  },
	{ id = "anthropic/claude-3-haiku",     displayName = "Claude Haiku",  integerLevers = false },
}

LLMConfig.MAX_HISTORY_DEPTH = 7

local _enabled = false
local _selectedModelId = "heuristic"

local function findModel(id: string)
	for _, m in ipairs(LLMConfig.MODELS) do
		if m.id == id then
			return m
		end
	end
	return nil
end

-- Returns the current effective config snapshot.
function LLMConfig.get()
	local model = findModel(_selectedModelId) or LLMConfig.MODELS[1]
	return {
		enabled = _enabled,
		modelId = model.id,
		displayName = model.displayName,
		integerLevers = model.integerLevers,
		isHeuristic = model.id == "heuristic",
	}
end

function LLMConfig.setEnabled(enabled: boolean)
	_enabled = enabled == true
end

-- No-op if modelId is not in the MODELS list.
function LLMConfig.setModel(modelId: string)
	if findModel(modelId) then
		_selectedModelId = modelId
	end
end

function LLMConfig.getModelIndex(): number
	for i, m in ipairs(LLMConfig.MODELS) do
		if m.id == _selectedModelId then
			return i
		end
	end
	return 1
end

function LLMConfig.cycleModel(delta: number)
	local idx = LLMConfig.getModelIndex()
	local count = #LLMConfig.MODELS
	idx = ((idx - 1 + delta) % count) + 1
	_selectedModelId = LLMConfig.MODELS[idx].id
end

return LLMConfig
