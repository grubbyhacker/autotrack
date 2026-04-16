-- Types.luau
-- Shared type definitions for all AutoTrack modules.
-- These mirror the normative schemas in prd_plan.md §15.

export type Mechanic = "RampJump" | "Chicane" | "CrestDip"
export type PadValue = "None" | "Boost" | "Brake"
export type PadSide = "ingress" | "egress"

export type ParsedRequest = {
	sector_id: number,
	mechanic: Mechanic,
}

export type Request = {
	request_id: string,
	raw_text: string,
	parsed: ParsedRequest,
	qualifiers: { string },
	timestamp: number,
}

export type SectorParams = {
	-- RampJump
	ramp_angle: number?,
	ramp_length: number?,
	gap_length: number?,
	landing_length: number?,
	-- Chicane
	amplitude: number?,
	transition_length: number?,
	corridor_width: number?,
	-- CrestDip
	height_or_depth: number?,
	radius: number?,
	sector_length: number?,
}

export type Pads = {
	ingress: PadValue,
	egress: PadValue,
}

export type SectorState = {
	sector_id: number,
	mechanic: Mechanic,
	params: SectorParams,
	pads: Pads,
	version: number,
}

export type AgentAction =
	{ type: "SetNumericLever", lever: string, value: number }
	| { type: "SetPad", pad: PadSide, value: PadValue }

export type RunMetrics = {
	entry_speed: number,
	exit_speed: number,
	airborne: boolean,
	air_distance: number,
	lateral_error: number,
	vertical_displacement: number,
	reacquired: boolean,
	lap_time: number,
	slowdown_ratio: number,
}

export type FailureType =
	"mechanic_integrity_failure"
	| "local_execution_failure"
	| "downstream_failure"
	| "system_failure"

export type FailureInfo = {
	type: FailureType,
	sector_id: number,
}

export type RunResult = {
	success: boolean,
	failure: FailureInfo?,
	metrics: RunMetrics,
}

export type Diagnostics = {
	failure_sector: number,
	hints: { string },
}

export type LegalActions = {
	numeric_levers: { string },
	pads: { "ingress" | "egress" },
}

export type FailurePacket = {
	request: Request,
	sector_state: SectorState,
	attempt_index: number,
	last_action: AgentAction?,
	run_result: RunResult,
	diagnostics: Diagnostics,
	legal_actions: LegalActions,
}

export type AttemptRecord = {
	attempt_index: number,
	action: AgentAction?,
	result: RunResult,
}

export type FinalStatus = "committed" | "reverted"

export type CIJob = {
	job_id: string,
	request: Request,
	initial_state: SectorState,
	working_state: SectorState,
	attempts: { AttemptRecord },
	final_status: FinalStatus,
}

return {}
