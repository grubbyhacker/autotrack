-- RampJumpBuilder.luau
-- Builds RampJump geometry from a SectorState.
-- prd_plan.md §4.1, Phase 4
--
-- Layout (entry → exit, all within the sector bounds):
--   [ingress pad] [ramp] [gap (air)] [landing] [egress pad]
--
-- All physical parts are placed via MCP using the entry CFrame as the
-- local origin.  No script instances are created here.

local Types = require(script.Parent.Parent.common.Types)
local Constants = require(script.Parent.Parent.common.Constants)

type SectorState = Types.SectorState

local RampJumpBuilder = {}

-- Build all physical parts for a RampJump sector.
-- entryFrame: CFrame at the sector entry boundary
-- exitFrame:  CFrame at the sector exit boundary
function RampJumpBuilder.build(state: SectorState, entryFrame: CFrame, exitFrame: CFrame)
	local p = state.params
	assert(p.ramp_angle,     "RampJumpBuilder: missing ramp_angle")
	assert(p.ramp_length,    "RampJumpBuilder: missing ramp_length")
	assert(p.gap_length,     "RampJumpBuilder: missing gap_length")
	assert(p.landing_length, "RampJumpBuilder: missing landing_length")

	-- TODO: Phase 4 — compute part CFrames and issue MCP createInstance/move calls
	error("RampJumpBuilder.build: not yet implemented")
end

return RampJumpBuilder
