-- LevelMappings.luau
-- Maps user-facing text synonyms to canonical mechanic names and
-- defines the legal numeric levers per mechanic.
-- prd_plan.md §3.2, §4

local LevelMappings = {}

-- Synonym → canonical mechanic name
-- Keys are lowercase for case-insensitive matching.
LevelMappings.MECHANIC_SYNONYMS = {
	["jump"]         = "RampJump",
	["ramp"]         = "RampJump",
	["ramp jump"]    = "RampJump",
	["chicane"]      = "Chicane",
	["s-curve"]      = "Chicane",
	["s curve"]      = "Chicane",
	["snake"]        = "Chicane",
	["crest"]        = "CrestDip",
	["dip"]          = "CrestDip",
	["crestdip"]     = "CrestDip",
	["crest dip"]    = "CrestDip",
	["hill"]         = "CrestDip",
	["valley"]       = "CrestDip",
}

-- Legal numeric levers per mechanic (used to populate FailurePacket.legal_actions)
LevelMappings.NUMERIC_LEVERS = {
	RampJump = { "ramp_angle", "ramp_length", "gap_length", "landing_length" },
	Chicane  = { "amplitude", "transition_length", "corridor_width" },
	CrestDip = { "height_or_depth", "radius", "sector_length" },
}

-- Default parameter values per mechanic (initial proposal baseline before qualifier biasing)
LevelMappings.DEFAULTS = {
	RampJump = {
		ramp_angle      = 20,
		ramp_length     = 12,
		gap_length      = 8,
		landing_length  = 12,
	},
	Chicane = {
		amplitude          = 5,
		transition_length  = 15,
		corridor_width     = 14,
	},
	CrestDip = {
		height_or_depth = 6,
		radius          = 20,
		sector_length   = 40,
	},
}

return LevelMappings
