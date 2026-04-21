-- Types.luau
-- Shared type definitions for all AutoTrack modules.
-- These mirror the normative schemas in prd_plan.md §15.

export type SectorKind = "Straight" | "Corner"
export type SectorMeta = { id: number, kind: SectorKind, entry: CFrame, exit: CFrame, partGroup: Folder? }

export type Mechanic = "RampJump" | "Chicane" | "CrestDip"
export type PadValue = "None" | "Boost5" | "Boost10" | "Boost25" | "Boost50" | "Brake5" | "Brake10" | "Brake25" | "Brake50"
export type PadSide = "ingress" | "egress"

export type ParsedRequest = {
	sector_id: number,
	mechanic: Mechanic?,
	request_kind: "Mechanic" | "Pad",
	pad_side: PadSide?,
	pad_value: PadValue?,
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
	mechanic: Mechanic?,
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
	airtime_distance: number,
	target_airborne: boolean?,
	target_air_distance: number?,
	target_vertical_displacement: number?,
	target_reacquired: boolean?,
	target_airtime_distance: number?,
	target_left_offset: number?,
	target_right_offset: number?,
	target_lateral_band_changes: number?,
	target_entered: boolean?,
	target_exited: boolean?,
	target_progress: number?,
	lap_time: number,
	slowdown_ratio: number,
	sector_peak_centerline_distance: { [number]: number }?,
	sector_peak_signed_lateral: { [number]: number }?,
	sector_peak_progress: { [number]: number }?,
	sector_peak_front_distance: { [number]: number }?,
	sector_peak_body_distance: { [number]: number }?,
	-- Phase 11 additions (optional, zero-default if MetricCollector unchanged)
	hang_time: number?,
	peak_lateral_g: number?,
	target_min_speed: number?,
	target_apex_min_speed: number?,
}

-- Phase 11 fitness signal. See plans/phase11.md §3.1, §10 and
-- src/integrity/ChallengeScore.luau for the formula.
export type ChallengeScore = {
	total: number,
	air: number,
	lateral: number,
	near_miss: number,
	time_cost: number,
	budget_used: number,
	over_budget: boolean,
}

export type FailureType =
	"mechanic_integrity_failure"
	| "local_execution_failure"
	| "downstream_failure"
	| "system_failure"

export type FailureInfo = {
	type: FailureType,
	sector_id: number,
	detail: string?,
}

export type RunResult = {
	success: boolean,
	failure: FailureInfo?,
	metrics: RunMetrics,
	failure_position: Vector3?,
	final_position: Vector3?,
	trajectory_tail: { Vector3 }?,
	-- Phase 11: populated only on success.
	score: ChallengeScore?,
}

export type Diagnostics = {
	failure_sector: number,
	hints: { string },
	failure_type: FailureType?,
	failure_detail: string?,
	target_entry_speed: number?,
	target_exit_speed: number?,
	target_reacquired: boolean?,
	target_airtime_distance: number?,
	target_apex_min_speed: number?,
	downstream_sector_state: SectorState?,
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
	proposed_state: SectorState?,
	result: RunResult,
	hints: { string }?,
}

export type OrchestratorAttempt = {
	sector_id: number,
	mechanic: Mechanic?,
	params_hint: string?,
	normalized_signature: string?,
	outcome: string,
	score: number?,
	slowdown_ratio: number?,
	failure_signature: string?,
	repair_iterations: number,
	decision_index: number,
	timestamp: number,
}

export type CandidateScore = {
	base_score_gain: number,
	track_sustainability: number,
	novelty_bonus: number,
	repeat_penalty: number,
	budget_risk_penalty: number,
	repair_complexity_penalty: number,
	total: number,
	reliability_index: number,
}

export type OrchestratorTrackIntent = {
	target_total_score: number,
	target_budget_used: number,
	diversity_pressure: { [string]: number },
}

export type OrchestratorSectorSnapshot = {
	mechanic: Mechanic?,
	params: SectorParams,
	score: number,
}

export type OrchestratorBudget = {
	used: number,
	over_budget: boolean,
}

export type OrchestratorAttemptBudget = {
	used: number,
	total: number,
}

export type OrchestratorLastResult = {
	sector_id: number,
	success: boolean,
	score: number,
	failure_reason: string?,
}

export type OrchestratorContext = {
	editable_sectors: { number },
	sector_states: { [number]: OrchestratorSectorSnapshot },
	budget: OrchestratorBudget,
	attempt_budget: OrchestratorAttemptBudget,
	last_result: OrchestratorLastResult?,
	attempt_history: { OrchestratorAttempt }?,
	sector_attempt_counts: { [number]: number }?,
	mechanic_repeat_pressure: { [string]: number }?,
	track_intent: OrchestratorTrackIntent?,
}

export type OrchestratorDecision = {
	action: "begin_loop"?,
	sector_id: number?,
	mechanic: Mechanic?,
	params_hint: string?,
	rationale: string?,
}

export type LLMTraceDirection = "prompt" | "response" | "error"
export type LLMTraceRole = "orchestrator" | "repair" | "proposal"
export type LLMTraceKind = "propose" | "repair" | "orchestrate"

export type LLMTraceEvent = {
	run_id: string,
	seq: number,
	timestamp_ms: number,
	role: LLMTraceRole,
	direction: LLMTraceDirection,
	provider: string?,
	model: string?,
	kind: LLMTraceKind,
	payload: { [string]: any },
}

export type LLMTraceRun = {
	run_id: string,
	started_at_ms: number,
	finished_at_ms: number?,
	event_count: number,
	owner: string?,
	mode: string?,
	job_id: string?,
	request_id: string?,
	meta: { [string]: any }?,
	summary: { [string]: any }?,
	events: { LLMTraceEvent },
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
