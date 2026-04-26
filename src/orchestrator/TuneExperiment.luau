--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local LaunchOutlier = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LaunchOutlier"))
local AttemptRunner = require(script.Parent.AttemptRunner)
local RuntimeContext = require(script.Parent.RuntimeContext)
local SectorApplier = require(script.Parent.Parent.Track.SectorApplier)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local Tracer = require(script.Parent.Tracer)
local TuneLab = require(script.Parent.TuneLab)
local UIState = require(script.Parent.UIState)

type SectorState = Types.SectorState
type RunResult = Types.RunResult
type ChallengeScore = Types.ChallengeScore
type AttrOverrides = { [string]: number }
type AttributeValue =
	boolean
	| number
	| string
	| Vector3
	| CFrame
	| Color3
	| BrickColor
	| UDim
	| UDim2
	| Rect
	| NumberSequence
	| ColorSequence
	| NumberRange
type AttrRestore = {
	values: { [string]: AttributeValue? },
	touched: { string },
}
type TunePassMetrics = any
type TunePassRecord = {
	pass_index: number,
	success: boolean,
	failure_type: string,
	failure_detail: string,
	params: Types.SectorParams,
	pads: Types.Pads,
	attrs: AttrOverrides,
	metrics: TunePassMetrics,
	challenge_score: ChallengeScore?,
	score: number?,
}
type TuneAggregate = {
	pass_count: number,
	success_count: number,
	failure_count: number,
	average_score: number,
	best_score: number,
	challenge_success_count: number,
	average_challenge_total: number,
	best_challenge_total: number,
	average_lap_time: number,
	average_entry_speed: number,
	average_exit_speed: number,
	worst_body_distance: number,
	last_failure: string,
	score: number,
}
type TuneCandidate = {
	label: string?,
	passes: number?,
	state: SectorState,
	attr_overrides: AttrOverrides?,
	clear_all_attrs: boolean?,
}
type TuneCandidateSummary = {
	label: string,
	state: {
		mechanic: Types.Mechanic?,
		params: Types.SectorParams,
		pads: Types.Pads,
	},
	attr_overrides: AttrOverrides,
	aggregate: TuneAggregate,
	records: any,
}
type TuneComparison = {
	baseline_label: string,
	candidate_label: string,
	heuristic_delta: number,
	challenge_delta: number,
	success_delta: number,
	heuristic_winner: string,
	challenge_winner: string,
}

local TuneExperiment = {}

local function cloneParams(source: Types.SectorParams): Types.SectorParams
	return {
		ramp_angle = source.ramp_angle,
		ramp_length = source.ramp_length,
		gap_length = source.gap_length,
		landing_length = source.landing_length,
		amplitude = source.amplitude,
		transition_length = source.transition_length,
		corridor_width = source.corridor_width,
		height_or_depth = source.height_or_depth,
		radius = source.radius,
		sector_length = source.sector_length,
	}
end

local function clonePads(source: Types.Pads): Types.Pads
	return {
		ingress = source.ingress,
		egress = source.egress,
	}
end

local function cloneAttrs(source: AttrOverrides?): AttrOverrides
	local copy: AttrOverrides = {}
	if source == nil then
		return copy
	end
	for key, value in pairs(source) do
		copy[key] = value
	end
	return copy
end

local function cloneState(state: SectorState): SectorState
	return {
		sector_id = state.sector_id,
		mechanic = state.mechanic,
		params = cloneParams(state.params),
		pads = clonePads(state.pads),
		version = state.version,
	}
end

local function activeSector(sectorId: number): Types.SectorMeta
	return RuntimeContext.getSectorById(sectorId)
end

local function applyAttrs(attrOverrides: AttrOverrides?, clearOthers: boolean?): AttrRestore
	local previous: AttrRestore = {
		values = {},
		touched = {},
	}
	if clearOthers == true then
		for _, spec in pairs(TuneLab.ATTR_SPECS) do
			local attrName = spec.workspace_attr
			previous.values[attrName] = workspace:GetAttribute(attrName)
			table.insert(previous.touched, attrName)
			workspace:SetAttribute(attrName, nil)
		end
	end
	for name, value in pairs(attrOverrides or {}) do
		local spec = TuneLab.ATTR_SPECS[name]
		if spec ~= nil then
			local attrName = spec.workspace_attr
			if previous.values[attrName] == nil then
				previous.values[attrName] = workspace:GetAttribute(attrName)
				table.insert(previous.touched, attrName)
			end
			workspace:SetAttribute(attrName, TuneLab.normalizeAttr(name, value))
		end
	end
	return previous
end

local function restoreAttrs(previous: AttrRestore): ()
	for _, attrName in ipairs(previous.touched) do
		workspace:SetAttribute(attrName, previous.values[attrName])
	end
end

local function bodyDistance(metrics: Types.RunMetrics, sectorId: number): number
	if type(metrics.target_peak_body_distance) == "number" then
		return metrics.target_peak_body_distance
	end
	if type(metrics.sector_peak_body_distance) == "table" then
		return metrics.sector_peak_body_distance[sectorId] or 0
	end
	return 0
end

local function passRecord(
	passIndex: number,
	sectorId: number,
	candidate: { state: SectorState, attr_overrides: AttrOverrides },
	result: RunResult
): TunePassRecord
	local metrics = result.metrics
	local launchOutlier = LaunchOutlier.classify(metrics)
	local normalizedState = candidate.state
	local record: TunePassRecord = {
		pass_index = passIndex,
		success = result.success == true,
		failure_type = if result.failure then tostring(result.failure.type) else "",
		failure_detail = result.failure and result.failure.detail or "",
		params = cloneParams(normalizedState.params),
		pads = clonePads(normalizedState.pads),
		attrs = cloneAttrs(candidate.attr_overrides),
		metrics = {
			entry_speed = metrics.entry_speed,
			exit_speed = metrics.exit_speed,
			lap_time = metrics.lap_time,
			slowdown_ratio = metrics.slowdown_ratio,
			air_distance = metrics.air_distance,
			vertical_displacement = metrics.vertical_displacement,
			airtime_distance = metrics.airtime_distance,
			target_airtime_distance = metrics.target_airtime_distance,
			hang_time = metrics.hang_time or 0,
			target_min_speed = metrics.target_min_speed,
			target_apex_min_speed = metrics.target_apex_min_speed,
			target_reacquired = metrics.target_reacquired,
			target_reacquire_distance = metrics.target_reacquire_distance,
			target_peak_body_distance = bodyDistance(metrics, sectorId),
			target_exit_angular_speed = metrics.target_exit_angular_speed,
			target_exit_vertical_speed = metrics.target_exit_vertical_speed,
			lateral_error = metrics.lateral_error,
			launch_outlier = launchOutlier.detected,
			launch_outlier_reasons = table.clone(launchOutlier.reasons),
		},
	}
	record.challenge_score = TuneLab.productionChallengeScore(normalizedState, result)
	record.score = TuneLab.scorePass({
		success = record.success,
		failure = result.failure,
		metrics = record.metrics,
	})
	return record
end

local function runPass(sectorId: number, state: SectorState): RunResult
	local sector = activeSector(sectorId)
	local result = select(
		1,
		AttemptRunner.run({
			mode = "isolated_sector",
			workingState = state,
			action = nil,
			targetSectorId = sectorId,
			entryFrame = sector.entry,
			exitFrame = sector.exit,
			sectors = RuntimeContext.getSectors(),
			car = RuntimeContext.getCar(),
			canonicalStart = RuntimeContext.getCanonicalStart(),
			onSectorChange = nil,
		})
	)
	return result
end

function TuneExperiment.runCandidate(candidate: TuneCandidate): TuneCandidateSummary
	assert(RuntimeContext.isReady(), "TuneExperiment.runCandidate: runtime context not ready")
	local sectorId = candidate.state.sector_id
	local normalizedState = TuneLab.normalizeState(cloneState(candidate.state))
	local passes = math.max(1, math.floor(candidate.passes or 1))
	local previousAttrs = applyAttrs(candidate.attr_overrides, candidate.clear_all_attrs == true)
	local records: { TunePassRecord } = {}

	UIState.appendLog(
		string.format("Experiment %s x%d", tostring(candidate.label or normalizedState.mechanic or "candidate"), passes)
	)

	local ok, runErr = pcall(function()
		for passIndex = 1, passes do
			local result = runPass(sectorId, normalizedState)
			local record = passRecord(passIndex, sectorId, {
				state = normalizedState,
				attr_overrides = candidate.attr_overrides or {},
			}, result)
			table.insert(records, record)
			Tracer.log(
				string.format(
					"tune_experiment_pass label=%s pass=%d %s",
					tostring(candidate.label or normalizedState.mechanic or "candidate"),
					passIndex,
					HttpService:JSONEncode(record)
				)
			)
		end
	end)

	restoreAttrs(previousAttrs)
	if not ok then
		error(tostring(runErr))
	end

	local aggregate: TuneAggregate = TuneLab.aggregateCandidate(records)
	local summary: TuneCandidateSummary = {
		label = candidate.label or normalizedState.mechanic or "candidate",
		state = {
			mechanic = normalizedState.mechanic,
			params = cloneParams(normalizedState.params),
			pads = clonePads(normalizedState.pads),
		},
		attr_overrides = cloneAttrs(candidate.attr_overrides),
		aggregate = aggregate,
		records = records,
	}
	Tracer.log(string.format("tune_experiment_candidate %s", HttpService:JSONEncode(summary)))
	return summary
end

function TuneExperiment.compareCandidates(candidates: { TuneCandidate }): {
	best: TuneCandidateSummary?,
	best_production: TuneCandidateSummary?,
	results: any,
	comparison: TuneComparison?,
}
	local results: { TuneCandidateSummary } = {}
	local best: TuneCandidateSummary? = nil
	local bestProduction: TuneCandidateSummary? = nil
	for _, candidate in ipairs(candidates) do
		local result = TuneExperiment.runCandidate(candidate)
		table.insert(results, result)
		if best == nil or (result.aggregate.score or 0) > (best.aggregate.score or 0) then
			best = result
		end
		if
			bestProduction == nil
			or (result.aggregate.average_challenge_total or 0)
				> (bestProduction.aggregate.average_challenge_total or 0)
		then
			bestProduction = result
		end
	end
	local comparison: TuneComparison? = nil
	if #results >= 2 then
		comparison = TuneLab.compareAggregatePair(results[1], results[2])
	end
	return {
		best = best,
		best_production = bestProduction,
		results = results,
		comparison = comparison,
	}
end

function TuneExperiment.restoreCommittedState(sectorId: number)
	local committed = SectorRegistry.getCommitted(sectorId)
	if committed == nil then
		return
	end
	local sector = activeSector(sectorId)
	SectorApplier.apply(committed, sector.entry, sector.exit)
end

return TuneExperiment
