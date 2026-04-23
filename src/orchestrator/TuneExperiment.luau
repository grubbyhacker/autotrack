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

local TuneExperiment = {}

local function cloneTable(source)
	local copy = {}
	for key, value in pairs(source or {}) do
		if type(value) == "table" then
			copy[key] = cloneTable(value)
		else
			copy[key] = value
		end
	end
	return copy
end

local function cloneState(state: SectorState): SectorState
	return {
		sector_id = state.sector_id,
		mechanic = state.mechanic,
		params = cloneTable(state.params),
		pads = cloneTable(state.pads),
		version = state.version,
	}
end

local function activeSector(sectorId: number)
	return RuntimeContext.getSectorById(sectorId)
end

local function applyAttrs(attrOverrides, clearOthers: boolean?)
	local previous = {
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

local function restoreAttrs(previous)
	for _, attrName in ipairs((previous and previous.touched) or {}) do
		workspace:SetAttribute(attrName, previous.values[attrName])
	end
end

local function bodyDistance(metrics, sectorId: number): number
	if type(metrics.target_peak_body_distance) == "number" then
		return metrics.target_peak_body_distance
	end
	if type(metrics.sector_peak_body_distance) == "table" then
		return metrics.sector_peak_body_distance[sectorId] or 0
	end
	return 0
end

local function passRecord(passIndex: number, sectorId: number, candidate, result)
	local metrics = result.metrics or {}
	local launchOutlier = LaunchOutlier.classify(metrics)
	local normalizedState = candidate.state
	local record = {
		pass_index = passIndex,
		success = result.success == true,
		failure_type = result.failure and result.failure.type or "",
		failure_detail = result.failure and result.failure.detail or "",
		params = cloneTable(normalizedState.params),
		pads = cloneTable(normalizedState.pads),
		attrs = cloneTable(candidate.attr_overrides),
		metrics = {
			entry_speed = metrics.entry_speed or 0,
			exit_speed = metrics.exit_speed or 0,
			lap_time = metrics.lap_time or 0,
			slowdown_ratio = metrics.slowdown_ratio or 0,
			air_distance = metrics.air_distance or 0,
			vertical_displacement = metrics.vertical_displacement or 0,
			airtime_distance = metrics.airtime_distance or 0,
			target_airtime_distance = metrics.target_airtime_distance,
			hang_time = metrics.hang_time or 0,
			target_min_speed = metrics.target_min_speed,
			target_apex_min_speed = metrics.target_apex_min_speed,
			target_reacquired = metrics.target_reacquired,
			target_reacquire_distance = metrics.target_reacquire_distance,
			target_peak_body_distance = bodyDistance(metrics, sectorId),
			target_exit_angular_speed = metrics.target_exit_angular_speed,
			target_exit_vertical_speed = metrics.target_exit_vertical_speed,
			lateral_error = metrics.lateral_error or 0,
			launch_outlier = launchOutlier.detected,
			launch_outlier_reasons = cloneTable(launchOutlier.reasons),
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

local function runPass(sectorId: number, state: SectorState)
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

function TuneExperiment.runCandidate(candidate)
	assert(RuntimeContext.isReady(), "TuneExperiment.runCandidate: runtime context not ready")
	local sectorId = candidate.state.sector_id
	local normalizedState = TuneLab.normalizeState(cloneState(candidate.state))
	local passes = math.max(1, math.floor(candidate.passes or 1))
	local previousAttrs = applyAttrs(candidate.attr_overrides, candidate.clear_all_attrs == true)
	local records = {}

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
		error(runErr)
	end

	local aggregate = TuneLab.aggregateCandidate(records)
	local summary = {
		label = candidate.label or normalizedState.mechanic or "candidate",
		state = {
			mechanic = normalizedState.mechanic,
			params = cloneTable(normalizedState.params),
			pads = cloneTable(normalizedState.pads),
		},
		attr_overrides = cloneTable(candidate.attr_overrides or {}),
		aggregate = aggregate,
		records = records,
	}
	Tracer.log(string.format("tune_experiment_candidate %s", HttpService:JSONEncode(summary)))
	return summary
end

function TuneExperiment.compareCandidates(candidates)
	local results = {}
	local best = nil
	local bestProduction = nil
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
	local comparison = nil
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
