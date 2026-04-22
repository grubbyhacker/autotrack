-- RequestParser.luau
-- Parses a plain-text user request into a typed Request.
-- prd_plan.md §3.2–3.4, Phase 6
--
-- Rules:
--   - must resolve to exactly one sector and one supported mechanic
--   - light synonym normalization is allowed (see LevelMappings)
--   - qualifiers are captured but impose no measurable obligation
--   - reject on ambiguity, missing sector, unsupported mechanic

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local PadValueUtils = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("PadValueUtils"))

type Request = Types.Request

local RequestParser = {}

local EDITABLE_STRAIGHTS = {
	[2] = true,
	[3] = true,
	[4] = true,
	[7] = true,
	[8] = true,
	[9] = true,
}

local QUALIFIER_WORDS = {
	really = true,
	tall = true,
	long = true,
	short = true,
	steep = true,
	gentle = true,
	tight = true,
	wide = true,
	narrow = true,
	shallow = true,
	deep = true,
	-- Phase 11: opt-in to Stage B challenge-up. The word itself has no
	-- geometry bias (MinimalProposer ignores it); JobRunner reads it to
	-- decide whether to run the escalation loop after a successful commit.
	extreme = true,
}

local PAD_VALUE_TOKENS = {
	boost = "Boost",
	brake = "Brake",
	clear = "None",
	remove = "None",
	none = "None",
}

local PAD_SIDE_PATTERNS = {
	{ pattern = "ingress", side = "ingress" },
	{ pattern = "entry", side = "ingress" },
	{ pattern = "egress", side = "egress" },
	{ pattern = "exit", side = "egress" },
}

local function trim(text: string): string
	return string.match(text, "^%s*(.-)%s*$") or ""
end

-- Parse raw text.  Returns (Request, nil) on success or (nil, errorString) on failure.
function RequestParser.parse(rawText: string, requestId: string): (Request?, string?)
	local cleaned = trim(rawText)
	if cleaned == "" then
		return nil, "empty request"
	end

	local lowered = string.lower(cleaned)
	local sectorMatches = {}
	local seenSectors = {}
	for digits in string.gmatch(lowered, "sector%s*(%d+)") do
		local id = tonumber(digits)
		if id and not seenSectors[id] then
			seenSectors[id] = true
			table.insert(sectorMatches, id)
		end
	end

	if #sectorMatches == 0 then
		return nil, "sector missing"
	end
	if #sectorMatches > 1 then
		return nil, "multiple sectors referenced"
	end

	local sectorId = sectorMatches[1]
	if not EDITABLE_STRAIGHTS[sectorId] then
		return nil, "sector is not an editable straight"
	end

	local mechanicsFound = {}
	local seenMechanics = {}
	local synonyms = {}
	for synonym, mechanic in pairs(LevelMappings.MECHANIC_SYNONYMS) do
		table.insert(synonyms, { synonym = synonym, mechanic = mechanic })
	end
	table.sort(synonyms, function(a, b)
		return #a.synonym > #b.synonym
	end)

	for _, item in ipairs(synonyms) do
		local pattern = "%f[%a]" .. item.synonym:gsub("%-", "%%-") .. "%f[%A]"
		if string.find(lowered, pattern) then
			if not seenMechanics[item.mechanic] then
				seenMechanics[item.mechanic] = true
				table.insert(mechanicsFound, item.mechanic)
			end
		end
	end

	local padValue = nil
	local sawPadToken = false
	for token, mappedValue in pairs(PAD_VALUE_TOKENS) do
		local pattern = "%f[%a]" .. token .. "%f[%A]"
		if string.find(lowered, pattern) then
			sawPadToken = true
			local resolvedValue = mappedValue
			if mappedValue ~= "None" then
				local amountMatch = string.match(lowered, pattern .. "%s*([%+%-]?%d+)")
				local amount = tonumber(amountMatch or "")
				resolvedValue = PadValueUtils.fromKindAmount(mappedValue, amount)
			end
			if padValue ~= nil and padValue ~= resolvedValue then
				return nil, "ambiguous pad value"
			end
			padValue = resolvedValue
		end
	end

	local padSide = nil
	local sawPadWord = string.find(lowered, "%f[%a]pad%f[%A]") ~= nil
	for _, item in ipairs(PAD_SIDE_PATTERNS) do
		local pattern = "%f[%a]" .. item.pattern .. "%f[%A]"
		if string.find(lowered, pattern) then
			if padSide ~= nil and padSide ~= item.side then
				return nil, "ambiguous pad side"
			end
			padSide = item.side
		end
	end

	local isPadRequest = sawPadWord or sawPadToken

	if isPadRequest and #mechanicsFound > 0 then
		return nil, "ambiguous request"
	end

	if isPadRequest then
		if padValue == nil then
			return nil, "pad value missing"
		end
		if padSide == nil then
			return nil, "pad side missing"
		end
		return {
			request_id = requestId,
			raw_text = cleaned,
			parsed = {
				sector_id = sectorId,
				mechanic = nil,
				request_kind = "Pad",
				pad_side = padSide,
				pad_value = padValue,
			},
			qualifiers = {},
			origin = "player",
			design_intent = nil,
			memory_context = nil,
			timestamp = os.time(),
		}, nil
	end

	if #mechanicsFound == 0 then
		return nil, "unsupported mechanic"
	end
	if #mechanicsFound > 1 then
		return nil, "ambiguous mechanic"
	end

	local qualifiers = {}
	local seenQualifiers = {}
	for word in string.gmatch(lowered, "[%a%-]+") do
		if QUALIFIER_WORDS[word] and not seenQualifiers[word] then
			seenQualifiers[word] = true
			table.insert(qualifiers, word)
		end
	end

	return {
		request_id = requestId,
		raw_text = cleaned,
		parsed = {
			sector_id = sectorId,
			mechanic = mechanicsFound[1],
			request_kind = "Mechanic",
			pad_side = nil,
			pad_value = nil,
		},
		qualifiers = qualifiers,
		origin = "player",
		design_intent = nil,
		memory_context = nil,
		timestamp = os.time(),
	}, nil
end

return RequestParser
