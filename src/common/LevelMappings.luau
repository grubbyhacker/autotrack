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

-- Min/max bounds per lever. Applied as a hard clamp after LLM output.
LevelMappings.LEVER_BOUNDS = {
	RampJump = {
		ramp_angle     = { min = 5,  max = 60  },
		ramp_length    = { min = 4,  max = 40  },
		gap_length     = { min = 2,  max = 40  },
		landing_length = { min = 4,  max = 40  },
	},
	Chicane = {
		amplitude        = { min = 2,  max = 24  },
		transition_length = { min = 6,  max = 30  },
		corridor_width   = { min = 8,  max = 22  },
	},
	CrestDip = {
		height_or_depth = { min = 4,  max = 30  },
		radius          = { min = 8,  max = 40  },
		sector_length   = { min = 20, max = 40  },
	},
}

-- Default parameter values per mechanic (initial proposal baseline before qualifier biasing)
LevelMappings.DEFAULTS = {
	RampJump = {
		ramp_angle      = 9,
		ramp_length     = 18,
		gap_length      = 6,
		landing_length  = 26,
	},
	Chicane = {
		amplitude          = 5,
		transition_length  = 15,
		corridor_width     = 14,
	},
	CrestDip = {
		height_or_depth = 8,
		radius          = 20,
		sector_length   = 30,
	},
}

return LevelMappings
