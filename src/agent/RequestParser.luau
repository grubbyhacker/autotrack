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
		},
		qualifiers = qualifiers,
		timestamp = os.time(),
	}, nil
end

return RequestParser
