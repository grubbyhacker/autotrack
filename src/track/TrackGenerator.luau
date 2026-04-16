-- TrackGenerator.luau
-- Generates the rectangular track topology at runtime.
-- prd_plan.md §2
--
-- Inputs: rows, cols (default 2×5)
-- Outputs:
--   - ordered list of sector descriptors (type, index, entry CFrame, exit CFrame)
--   - corner sectors (fixed, non-editable)
--   - straight sectors (editable, clockwise-numbered from canonical start)
--
-- Physical parts are spawned via MCP using the transforms produced here.
-- This module owns only the topology math; no Instance creation happens here.

local Constants = require(script.Parent.Parent.common.Constants)

export type SectorKind = "straight" | "corner"

export type SectorDescriptor = {
	index: number,         -- clockwise order from canonical start (1-based)
	kind: SectorKind,
	straight_index: number?,  -- 1-based among editable straights only; nil for corners
	entry: CFrame,
	exit: CFrame,
}

local TrackGenerator = {}

-- Generate the full ordered sector list for a rows×cols rectangle.
-- Returns an array of SectorDescriptor in clockwise order.
function TrackGenerator.generate(rows: number?, cols: number?): { SectorDescriptor }
	rows = rows or Constants.TRACK_ROWS
	cols = cols or Constants.TRACK_COLS

	-- TODO: Phase 1 — compute entry/exit CFrames for each segment of the
	-- rectangle, interleaving straights and 90-degree corners.
	-- Each straight has STRAIGHT_LENGTH; each corner turns 90 degrees.
	-- All transforms are cardinal-aligned.

	error("TrackGenerator.generate: not yet implemented")
end

-- Returns the canonical start CFrame (before sector 1).
function TrackGenerator.canonicalStart(): CFrame
	-- TODO: Phase 1
	error("TrackGenerator.canonicalStart: not yet implemented")
end

return TrackGenerator
