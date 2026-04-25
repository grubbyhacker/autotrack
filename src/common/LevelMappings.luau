--!strict

-- LevelMappings.luau
-- Maps user-facing text synonyms to canonical mechanic names and
-- defines the legal numeric levers per mechanic.
-- prd_plan.md §3.2, §4

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))

type Mechanic = Types.Mechanic
type SectorParams = Types.SectorParams

type LeverBounds = {
	min: number,
	max: number,
}

type NumericLeverMap = {
	RampJump: { string },
	Chicane: { string },
	CrestDip: { string },
}

type LeverBoundsMap = {
	RampJump: { [string]: LeverBounds },
	Chicane: { [string]: LeverBounds },
	CrestDip: { [string]: LeverBounds },
}

type DefaultParamsMap = {
	RampJump: SectorParams,
	Chicane: SectorParams,
	CrestDip: SectorParams,
}

type LevelMappingsModule = {
	MECHANIC_SYNONYMS: { [string]: Mechanic },
	NUMERIC_LEVERS: NumericLeverMap,
	LEVER_BOUNDS: LeverBoundsMap,
	DEFAULTS: DefaultParamsMap,
}

local LevelMappings = {} :: LevelMappingsModule

-- Synonym → canonical mechanic name
-- Keys are lowercase for case-insensitive matching.
LevelMappings.MECHANIC_SYNONYMS = {
	["jump"] = "RampJump",
	["ramp"] = "RampJump",
	["ramp jump"] = "RampJump",
	["chicane"] = "Chicane",
	["s-curve"] = "Chicane",
	["s curve"] = "Chicane",
	["snake"] = "Chicane",
	["crest"] = "CrestDip",
	["dip"] = "CrestDip",
	["crestdip"] = "CrestDip",
	["crest dip"] = "CrestDip",
	["hill"] = "CrestDip",
	["valley"] = "CrestDip",
}

-- Legal numeric levers per mechanic (used to populate FailurePacket.legal_actions)
LevelMappings.NUMERIC_LEVERS = {
	RampJump = { "ramp_angle", "ramp_length", "gap_length", "landing_length" },
	Chicane = { "amplitude", "transition_length", "corridor_width" },
	CrestDip = { "height_or_depth", "radius", "sector_length" },
}

-- Min/max bounds per lever. Applied as a hard clamp after LLM output.
LevelMappings.LEVER_BOUNDS = {
	RampJump = {
		ramp_angle = { min = 3, max = 20 },
		ramp_length = { min = 20, max = 52 },
		gap_length = { min = 2, max = 18 },
		landing_length = { min = 18, max = 72 },
	},
	Chicane = {
		amplitude = { min = 4, max = 10 },
		transition_length = { min = 5, max = 32 },
		corridor_width = { min = 6, max = 18 },
	},
	CrestDip = {
		height_or_depth = { min = 5, max = 32 },
		radius = { min = 8, max = 40 },
		sector_length = { min = 18, max = 36 },
	},
}

-- Default parameter values per mechanic (initial proposal baseline before qualifier biasing)
LevelMappings.DEFAULTS = {
	RampJump = {
		ramp_angle = 10,
		ramp_length = 34,
		gap_length = 8,
		landing_length = 26,
	},
	Chicane = {
		amplitude = 7,
		transition_length = 11,
		corridor_width = 12,
	},
	CrestDip = {
		height_or_depth = 8,
		radius = 18,
		sector_length = 28,
	},
}

return LevelMappings
