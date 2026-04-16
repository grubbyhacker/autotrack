-- RequestParser.luau
-- Parses a plain-text user request into a typed Request.
-- prd_plan.md §3.2–3.4, Phase 6
--
-- Rules:
--   - must resolve to exactly one sector and one supported mechanic
--   - light synonym normalization is allowed (see LevelMappings)
--   - qualifiers are captured but impose no measurable obligation
--   - reject on ambiguity, missing sector, unsupported mechanic

local Types = require(script.Parent.Parent.common.Types)
local LevelMappings = require(script.Parent.Parent.common.LevelMappings)

type Request = Types.Request

local RequestParser = {}

-- Parse raw text.  Returns (Request, nil) on success or (nil, errorString) on failure.
function RequestParser.parse(rawText: string, requestId: string): (Request?, string?)
	-- TODO: Phase 6
	-- 1. lowercase + trim
	-- 2. extract sector number (e.g. "sector 3", "sector3")
	-- 3. match mechanic synonym from LevelMappings.MECHANIC_SYNONYMS
	-- 4. extract qualifier words
	-- 5. validate — reject if sector missing, mechanic missing/ambiguous
	error("RequestParser.parse: not yet implemented")
end

return RequestParser
