local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local LaunchOutlier = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LaunchOutlier"))
local PadValueUtils = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("PadValueUtils"))
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local SectorApplier = require(script.Parent.Parent.Track.SectorApplier)
local AttemptRunner = require(script.Parent.AttemptRunner)
local JobLock = require(script.Parent.JobLock)
local MinimalProposer = require(script.Parent.MinimalProposer)
local RuntimeContext = require(script.Parent.RuntimeContext)
local Tracer = require(script.Parent.Tracer)
local TuneExperiment = require(script.Parent.TuneExperiment)
local TuneLab = require(script.Parent.TuneLab)
local UIState = require(script.Parent.UIState)

local TuneMode = {}

local DEFAULT_SECTOR_ID = 3
local AUTO_LOOP_WAIT_SECONDS = 0.2
local IDLE_WAIT_SECONDS = 0.05
local HISTORY_LIMIT = 4
local MAX_RUN_ATTEMPTS = 20
local DEFAULT_AUTO_RUN = false

local ATTR_SPECS = TuneLab.ATTR_SPECS

local _active = false
local _token = 0
local _sectorId = DEFAULT_SECTOR_ID
local _mechanic = nil
local _workingState = nil
local _baselineState = nil
local _passCount = 0
local _lastResultText = ""
local _lastFailureText = ""
local _attrOverrides = {}
local _pendingStopFinalize = false
local _recentPasses = {}
local _bestPass = nil
local _promotionSnapshot = ""
local _autoRun = DEFAULT_AUTO_RUN
local _runInFlight = false
local _candidateVersion = 0
local _runSerial = 0
local _lastBatch = nil
local _bestBatch = nil
local _lastCompare = nil

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

local function cloneState(state)
	return {
		sector_id = state.sector_id,
		mechanic = state.mechanic,
		params = cloneTable(state.params),
		pads = {
			ingress = state.pads.ingress,
			egress = state.pads.egress,
		},
		version = state.version,
	}
end

local function activeSector()
	return RuntimeContext.getSectorById(_sectorId)
end

local function currentCommittedState()
	local committed = SectorRegistry.getCommitted(_sectorId)
	assert(committed ~= nil, "TuneMode: missing committed state")
	return committed
end

local function productionBaselineState(mechanic: string)
	local baseline, err = MinimalProposer.productionBaseline(_sectorId, mechanic, {})
	if baseline ~= nil then
		return baseline
	end

	UIState.appendLog("Tune baseline fallback: " .. tostring(err))
	return {
		sector_id = _sectorId,
		mechanic = mechanic,
		params = cloneTable(LevelMappings.DEFAULTS[mechanic] or {}),
		pads = {
			ingress = "None",
			egress = "None",
		},
		version = currentCommittedState().version,
	}
end

local function bodyDistance(metrics): number
	if type(metrics.target_peak_body_distance) == "number" then
		return metrics.target_peak_body_distance
	end
	if type(metrics.sector_peak_body_distance) == "table" then
		return metrics.sector_peak_body_distance[_sectorId] or 0
	end
	return 0
end

local function paramSummary(state): string
	if state == nil or state.mechanic == nil then
		return "flat"
	end
	local pieces = {}
	for _, lever in ipairs(LevelMappings.NUMERIC_LEVERS[state.mechanic] or {}) do
		local value = state.params[lever]
		if type(value) == "number" then
			table.insert(pieces, string.format("%s=%s", lever, tostring(value)))
		end
	end
	table.insert(pieces, string.format("ingress=%s", state.pads.ingress))
	table.insert(pieces, string.format("egress=%s", state.pads.egress))
	return table.concat(pieces, " | ")
end

local function attrSummary(): string
	local keys = {}
	for name, _ in pairs(_attrOverrides) do
		table.insert(keys, name)
	end
	table.sort(keys)
	if #keys == 0 then
		return ""
	end
	local pieces = {}
	for _, name in ipairs(keys) do
		table.insert(pieces, string.format("%s=%s", name, tostring(_attrOverrides[name])))
	end
	return table.concat(pieces, " | ")
end

local function boundsSummary(): string
	if _mechanic == nil then
		return ""
	end
	return TuneLab.formatBoundsSummary(_mechanic)
end

local function historySlots()
	local slots = table.create(HISTORY_LIMIT, "")
	for index = 1, HISTORY_LIMIT do
		slots[index] = if _recentPasses[index] ~= nil then HttpService:JSONEncode(_recentPasses[index]) else ""
	end
	return slots
end

local function bestPassJson(): string
	if _bestPass == nil then
		return ""
	end
	return HttpService:JSONEncode(_bestPass)
end

local function lastPassJson(): string
	if #_recentPasses == 0 then
		return ""
	end
	return HttpService:JSONEncode(_recentPasses[1])
end

local function lastBatchJson(): string
	if _lastBatch == nil then
		return ""
	end
	return HttpService:JSONEncode(_lastBatch)
end

local function bestBatchJson(): string
	if _bestBatch == nil then
		return ""
	end
	return HttpService:JSONEncode(_bestBatch)
end

local function baselineSnapshotJson(): string
	if _baselineState == nil then
		return ""
	end
	return HttpService:JSONEncode({
		mechanic = _baselineState.mechanic,
		params = cloneTable(_baselineState.params),
		pads = cloneTable(_baselineState.pads),
		version = _baselineState.version,
	})
end

local function lastCompareJson(): string
	if _lastCompare == nil then
		return ""
	end
	return HttpService:JSONEncode(_lastCompare)
end

local function promotionSnapshot(): string
	return _promotionSnapshot
end

local function compactBatchRecord(batch)
	return {
		run_id = batch.run_id,
		source = batch.source,
		candidate_version = batch.candidate_version,
		requested_passes = batch.requested_passes,
		completed_passes = batch.completed_passes,
		mechanic = batch.mechanic,
		params = cloneTable(batch.params),
		pads = cloneTable(batch.pads),
		attrs = cloneTable(batch.attrs),
		aggregate = cloneTable(batch.aggregate),
	}
end

local function syncTelemetry()
	local bestScore = if _bestPass ~= nil then _bestPass.score or 0 else 0
	local history = historySlots()
	UIState.setTuneTelemetry({
		active = _active,
		sector_id = _sectorId,
		mechanic = _mechanic,
		pass_count = _passCount,
		last_result = _lastResultText,
		last_failure = _lastFailureText,
		param_summary = paramSummary(_workingState),
		attr_summary = attrSummary(),
		bounds_summary = boundsSummary(),
		active_target_speed = _attrOverrides.car_target_speed or 0,
		best_score = bestScore,
		auto_run = _autoRun,
		run_in_flight = _runInFlight,
		candidate_version = _candidateVersion,
		last_run_id = if _lastBatch ~= nil then _lastBatch.run_id or 0 else 0,
		last_pass_json = lastPassJson(),
		best_pass_json = bestPassJson(),
		last_batch_json = lastBatchJson(),
		best_batch_json = bestBatchJson(),
		history_json = HttpService:JSONEncode(_recentPasses),
		history_1 = history[1],
		history_2 = history[2],
		history_3 = history[3],
		history_4 = history[4],
		baseline_snapshot = baselineSnapshotJson(),
		last_compare_json = lastCompareJson(),
		promotion_snapshot = promotionSnapshot(),
	})
end

local function applyCameraOverride()
	local sector = activeSector()
	local focus = sector.entry.Position:Lerp(sector.exit.Position, 0.35) + Vector3.yAxis * 4
	local position = focus + Vector3.yAxis * 34 + sector.entry.RightVector * 70 - sector.entry.LookVector * 34
	UIState.setCameraOverride(position, focus, 68)
end

local function clearTuneAttrs()
	for name, spec in pairs(ATTR_SPECS) do
		if _attrOverrides[name] ~= nil then
			workspace:SetAttribute(spec.workspace_attr, nil)
		end
	end
	_attrOverrides = {}
end

local function applyState(state)
	local sector = activeSector()
	SectorApplier.apply(state, sector.entry, sector.exit)
	UIState.setSectorMechanic(_sectorId, state.mechanic)
end

local function restoreCommittedState()
	local committed = cloneState(currentCommittedState())
	_workingState = cloneState(committed)
	_mechanic = committed.mechanic
	applyState(committed)
end

local function clearRunHistory()
	_recentPasses = {}
	_bestPass = nil
	_promotionSnapshot = ""
	_lastBatch = nil
	_bestBatch = nil
	_lastCompare = nil
end

local function finaliseStop()
	restoreCommittedState()
	clearTuneAttrs()
	UIState.clearCameraOverride()
	_active = false
	_mechanic = nil
	_workingState = nil
	_baselineState = nil
	_passCount = 0
	_lastResultText = ""
	_lastFailureText = ""
	_pendingStopFinalize = false
	_autoRun = DEFAULT_AUTO_RUN
	_runInFlight = false
	_candidateVersion = 0
	_runSerial = 0
	clearRunHistory()
	UIState.clearTuneTelemetry()
	UIState.publishReady()
	UIState.appendLog("Tune mode stopped")
	Tracer.log(string.format("tune_stop sector=%d", _sectorId))
end

local function setActiveSessionState(state, phaseLabel: string)
	_workingState = cloneState(state)
	_mechanic = state.mechanic
	UIState.resetLogs()
	UIState.clearError()
	UIState.clearLLMWarning()
	UIState.hideFailure()
	UIState.hideFailureBanner()
	UIState.setBusy(false)
	UIState.setPhase("TuneMode", phaseLabel)
	UIState.setRequestContext(string.format("/tune %s", string.lower(_mechanic)), _sectorId, _mechanic)
	UIState.setExplanation(
		"Use /tune show | run | compare | auto | set | pad | attr | reset | revert | commit | promote | stop"
	)
	UIState.clearRepairAction()
	applyCameraOverride()
	applyState(_workingState)
	syncTelemetry()
end

local function appendStatus(prefix: string)
	UIState.appendLog(string.format("%s: %s", prefix, paramSummary(_workingState)))
	UIState.appendLog(
		string.format(
			"Tune staged: candidate=v%d auto=%s run=%s",
			_candidateVersion,
			tostring(_autoRun),
			if _runInFlight then "busy" else "idle"
		)
	)
	if boundsSummary() ~= "" then
		UIState.appendLog("Tune bounds: " .. boundsSummary())
	end
	if attrSummary() ~= "" then
		UIState.appendLog("Tune attrs: " .. attrSummary())
	end
	if _baselineState ~= nil then
		UIState.appendLog("Tune baseline: " .. paramSummary(_baselineState))
	end
	if _lastBatch ~= nil then
		local aggregate = _lastBatch.aggregate or {}
		UIState.appendLog(
			string.format(
				"Tune batch: run=%d candidate=v%d %d/%d score=%.1f",
				_lastBatch.run_id or 0,
				_lastBatch.candidate_version or 0,
				aggregate.success_count or 0,
				aggregate.pass_count or 0,
				aggregate.score or 0
			)
		)
	end
	if #_recentPasses > 0 then
		local last = _recentPasses[1]
		UIState.appendLog(
			string.format(
				"Tune last pass: pass=%d success=%s score=%.1f",
				last.pass_index or 0,
				tostring(last.success == true),
				last.score or 0
			)
		)
	end
	if _bestPass ~= nil then
		UIState.appendLog(
			string.format("Tune best pass: pass=%d score=%.1f", _bestPass.pass_index or 0, _bestPass.score or 0)
		)
	end
	if _bestBatch ~= nil then
		UIState.appendLog(
			string.format(
				"Tune best batch: run=%d candidate=v%d score=%.1f",
				_bestBatch.run_id or 0,
				_bestBatch.candidate_version or 0,
				(_bestBatch.aggregate and _bestBatch.aggregate.score) or 0
			)
		)
	end
	if _lastCompare ~= nil and _lastCompare.summary ~= nil then
		local summary = _lastCompare.summary
		UIState.appendLog(
			string.format(
				"Tune compare: heuristic=%s prod=%s dh=%.1f dp=%.1f",
				tostring(summary.heuristic_winner or ""),
				tostring(summary.challenge_winner or ""),
				summary.heuristic_delta or 0,
				summary.challenge_delta or 0
			)
		)
	end
end

local function compactPassRecord(record)
	return {
		pass_index = record.pass_index,
		run_id = record.run_id,
		candidate_version = record.candidate_version,
		mechanic = record.mechanic,
		success = record.success,
		score = record.score,
		challenge_score = cloneTable(record.challenge_score),
		failure_type = record.failure_type,
		failure_detail = record.failure_detail,
		params = cloneTable(record.params),
		pads = cloneTable(record.pads),
		attrs = cloneTable(record.attrs),
		metrics = cloneTable(record.metrics),
	}
end

local function buildPassRecord(
	passIndex: number,
	runId: number,
	candidateVersion: number,
	stateSnapshot,
	attrSnapshot,
	result
)
	local metrics = result.metrics or {}
	local launchOutlier = LaunchOutlier.classify(metrics)
	local record = {
		pass_index = passIndex,
		run_id = runId,
		candidate_version = candidateVersion,
		mechanic = stateSnapshot.mechanic,
		params = cloneTable(stateSnapshot.params),
		pads = cloneTable(stateSnapshot.pads),
		attrs = cloneTable(attrSnapshot),
		success = result.success == true,
		failure_type = result.failure and result.failure.type or "",
		failure_detail = result.failure and result.failure.detail or "",
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
			target_peak_body_distance = bodyDistance(metrics),
			target_exit_angular_speed = metrics.target_exit_angular_speed,
			target_exit_vertical_speed = metrics.target_exit_vertical_speed,
			lateral_error = metrics.lateral_error or 0,
			launch_outlier = launchOutlier.detected,
			launch_outlier_reasons = cloneTable(launchOutlier.reasons),
		},
	}
	record.challenge_score = TuneLab.productionChallengeScore(stateSnapshot, result)
	record.score = TuneLab.scorePass({
		success = record.success,
		failure = result.failure,
		metrics = record.metrics,
	})
	return compactPassRecord(record)
end

local function buildBatchRecord(
	runId: number,
	source: string,
	candidateVersion: number,
	requestedPasses: number,
	stateSnapshot,
	attrSnapshot,
	records
)
	return compactBatchRecord({
		run_id = runId,
		source = source,
		candidate_version = candidateVersion,
		requested_passes = requestedPasses,
		completed_passes = #records,
		mechanic = stateSnapshot.mechanic,
		params = cloneTable(stateSnapshot.params),
		pads = cloneTable(stateSnapshot.pads),
		attrs = cloneTable(attrSnapshot),
		aggregate = TuneLab.aggregateCandidate(records),
	})
end

local function updateBestPass(record)
	if _bestPass == nil or (record.score or 0) > (_bestPass.score or 0) then
		_bestPass = compactPassRecord(record)
		_promotionSnapshot = HttpService:JSONEncode({
			mechanic = _bestPass.mechanic,
			params = cloneTable(_bestPass.params),
			pads = cloneTable(_bestPass.pads),
			attrs = cloneTable(_bestPass.attrs),
			score = _bestPass.score,
			metrics = cloneTable(_bestPass.metrics),
			source_pass = _bestPass.pass_index,
			run_id = _bestPass.run_id,
			candidate_version = _bestPass.candidate_version,
		})
	end
end

local function updateBestBatch(batch)
	if
		_bestBatch == nil
		or ((batch.aggregate and batch.aggregate.score) or 0)
			> ((_bestBatch.aggregate and _bestBatch.aggregate.score) or 0)
	then
		_bestBatch = compactBatchRecord(batch)
	end
end

local function recordPass(record)
	table.insert(_recentPasses, 1, compactPassRecord(record))
	while #_recentPasses > HISTORY_LIMIT do
		table.remove(_recentPasses)
	end
	updateBestPass(record)
end

local function recordBatch(batch)
	_lastBatch = compactBatchRecord(batch)
	updateBestBatch(batch)
end

local function normalizeAttrValue(name: string, value: number): number
	local normalized = TuneLab.normalizeAttr(name, value)
	if normalized ~= nil then
		return normalized
	end
	return value
end

local function phaseLabelForMechanic(): string
	return string.format("Tune Mode — Sector %d · %s", _sectorId, tostring(_mechanic))
end

local function stageLabel(): string
	return string.format("staged v%d", _candidateVersion)
end

local function markCandidateChanged()
	_candidateVersion += 1
	_lastResultText = stageLabel()
	_lastFailureText = ""
	_lastCompare = nil
	_promotionSnapshot = ""
end

local function ensureMutableState()
	if not _active or _workingState == nil then
		return false, "tune mode not running"
	end
	if _runInFlight or JobLock.isHeld() then
		return false, "tune run in flight; try again shortly"
	end
	return true, nil
end

local function pauseAutoForStagedEdit()
	if _autoRun then
		_autoRun = false
		UIState.appendLog("Tune auto paused for staged edit")
	end
end

local function runBatch(requestedPasses: number, source: string): (boolean, string?)
	if not _active or _workingState == nil then
		return false, "tune mode not running"
	end
	if _runInFlight then
		return false, "tune run in flight; try again shortly"
	end

	local runId = _runSerial + 1
	_runSerial = runId
	_runInFlight = true

	local stateSnapshot = cloneState(_workingState)
	local attrSnapshot = cloneTable(_attrOverrides)
	local candidateVersion = _candidateVersion
	local token = _token

	_lastResultText = string.format("run %d queued x%d", runId, requestedPasses)
	_lastFailureText = ""
	syncTelemetry()
	Tracer.log(
		string.format(
			"tune_batch_start sector=%d run=%d candidate=%d source=%s attempts=%d",
			_sectorId,
			runId,
			candidateVersion,
			source,
			requestedPasses
		)
	)

	task.spawn(function()
		local records = {}
		local batchError = nil

		for attemptIndex = 1, requestedPasses do
			local acquired = false
			while token == _token and _active do
				if JobLock.tryAcquire() then
					acquired = true
					break
				end
				task.wait(IDLE_WAIT_SECONDS)
			end

			if not acquired then
				break
			end

			local passIndex = _passCount + 1
			UIState.setPhase(
				"TunePass",
				string.format(
					"Tune %s — Sector %d run %d pass %d/%d",
					source,
					_sectorId,
					runId,
					attemptIndex,
					requestedPasses
				)
			)
			Tracer.log(
				string.format(
					"tune_pass_start sector=%d run=%d candidate=%d pass=%d mechanic=%s",
					_sectorId,
					runId,
					candidateVersion,
					passIndex,
					tostring(stateSnapshot.mechanic)
				)
			)

			local ok, result = pcall(function()
				return AttemptRunner.run({
					mode = "isolated_sector",
					workingState = stateSnapshot,
					action = nil,
					targetSectorId = _sectorId,
					entryFrame = activeSector().entry,
					exitFrame = activeSector().exit,
					sectors = RuntimeContext.getSectors(),
					car = RuntimeContext.getCar(),
					canonicalStart = RuntimeContext.getCanonicalStart(),
					onSectorChange = function(id, entering)
						if entering then
							UIState.setCurrentSector(id)
						end
					end,
				})
			end)

			JobLock.release()

			if not ok then
				batchError = tostring(result)
				UIState.setError("tune pass error: " .. batchError)
				UIState.appendLog("Tune pass error: " .. batchError)
				Tracer.log(
					string.format(
						"tune_pass_error sector=%d run=%d candidate=%d pass=%d err=%s",
						_sectorId,
						runId,
						candidateVersion,
						passIndex,
						batchError
					)
				)
				break
			end

			_passCount += 1
			UIState.publishAttemptResult(result, "isolated_sector")
			local record = buildPassRecord(passIndex, runId, candidateVersion, stateSnapshot, attrSnapshot, result)
			table.insert(records, record)
			recordPass(record)
			if record.metrics and record.metrics.launch_outlier == true then
				local reasons = table.concat(record.metrics.launch_outlier_reasons or {}, ",")
				UIState.appendLog(
					string.format(
						"Tune launch outlier pass %d: hang=%.2fs airtime=%.1f vertical=%.1f [%s]",
						passIndex,
						record.metrics.hang_time or 0,
						math.max(record.metrics.airtime_distance or 0, record.metrics.target_airtime_distance or 0),
						record.metrics.vertical_displacement or 0,
						reasons
					)
				)
				Tracer.log(
					string.format(
						"tune_launch_outlier sector=%d run=%d candidate=%d pass=%d hang=%.2f airtime=%.1f vertical=%.1f reasons=%s",
						_sectorId,
						runId,
						candidateVersion,
						passIndex,
						record.metrics.hang_time or 0,
						math.max(record.metrics.airtime_distance or 0, record.metrics.target_airtime_distance or 0),
						record.metrics.vertical_displacement or 0,
						reasons
					)
				)
			end
			Tracer.log(
				string.format(
					"tune_pass_record sector=%d run=%d candidate=%d pass=%d %s",
					_sectorId,
					runId,
					candidateVersion,
					passIndex,
					HttpService:JSONEncode(record)
				)
			)

			if result.success then
				UIState.hideFailure()
				UIState.appendLog(
					string.format(
						"Tune pass %d ok: %.2fs score=%.1f",
						passIndex,
						result.metrics and result.metrics.lap_time or -1,
						record.score or 0
					)
				)
				Tracer.log(string.format("tune_pass_complete sector=%d run=%d pass=%d", _sectorId, runId, passIndex))
			else
				local failureText = string.format(
					"%s%s",
					tostring(result.failure and result.failure.type or "unknown"),
					if result.failure
							and result.failure.detail
							and result.failure.detail ~= ""
						then " · " .. tostring(result.failure.detail)
						else ""
				)
				UIState.showFailure(result)
				UIState.appendLog(string.format("Tune pass %d fail: %s", passIndex, failureText))
				Tracer.log(
					string.format(
						"tune_pass_fail sector=%d run=%d pass=%d type=%s detail=%s",
						_sectorId,
						runId,
						passIndex,
						tostring(result.failure and result.failure.type or "unknown"),
						tostring(result.failure and result.failure.detail or "")
					)
				)
			end

			if token ~= _token or not _active then
				break
			end
		end

		_runInFlight = false

		if batchError ~= nil then
			_lastResultText = "error"
			_lastFailureText = batchError
		elseif #records > 0 then
			local batch =
				buildBatchRecord(runId, source, candidateVersion, requestedPasses, stateSnapshot, attrSnapshot, records)
			local aggregate = batch.aggregate or {}
			recordBatch(batch)
			_lastResultText = string.format(
				"run %d x%d score=%.1f (%d/%d)",
				runId,
				batch.completed_passes or #records,
				aggregate.score or 0,
				aggregate.success_count or 0,
				aggregate.pass_count or #records
			)
			_lastFailureText = aggregate.last_failure or ""
			UIState.appendLog(
				string.format(
					"Tune batch %d done: %d/%d score=%.1f",
					runId,
					aggregate.success_count or 0,
					aggregate.pass_count or #records,
					aggregate.score or 0
				)
			)
			Tracer.log(string.format("tune_batch_complete sector=%d %s", _sectorId, HttpService:JSONEncode(batch)))
		else
			_lastResultText = "idle"
			_lastFailureText = ""
		end

		if _pendingStopFinalize then
			finaliseStop()
			return
		end
		if token ~= _token or not _active then
			return
		end

		UIState.setPhase("TuneMode", phaseLabelForMechanic())
		syncTelemetry()
	end)

	return true, nil
end

function TuneMode.isActive(): boolean
	return _active
end

function TuneMode.experimentalBounds(mechanic: string)
	return TuneLab.experimentalBounds(mechanic)
end

function TuneMode.start(mechanic: string, sectorId: number?): (boolean, string?)
	if _active then
		return false, "tune mode already active"
	end
	assert(RuntimeContext.isReady(), "TuneMode.start: runtime context not ready")
	if JobLock.isHeld() then
		return false, "track is busy; try again shortly"
	end

	_sectorId = sectorId or DEFAULT_SECTOR_ID
	_baselineState = cloneState(productionBaselineState(mechanic))
	local committed = currentCommittedState()
	local nextState = if committed.mechanic == mechanic then cloneState(committed) else cloneState(_baselineState)

	_active = true
	_token += 1
	_passCount = 0
	_lastResultText = "staged v1"
	_lastFailureText = ""
	_pendingStopFinalize = false
	_autoRun = DEFAULT_AUTO_RUN
	_runInFlight = false
	_candidateVersion = 1
	_runSerial = 0
	clearRunHistory()
	setActiveSessionState(nextState, string.format("Tune Mode — Sector %d · %s", _sectorId, mechanic))
	UIState.appendLog(string.format("Tune mode on: sector %d %s", _sectorId, mechanic))
	UIState.appendLog(
		"Tune staged: use /tune run <n> or /tune compare <n> for controlled evaluation, or /tune auto on for continuous looping"
	)
	appendStatus("Tune state")
	Tracer.log(string.format("tune_start sector=%d mechanic=%s", _sectorId, mechanic))

	task.spawn(function()
		local token = _token
		while token == _token do
			if _pendingStopFinalize and not _runInFlight then
				finaliseStop()
				break
			end
			if not _active then
				break
			end
			if _autoRun and not _runInFlight then
				runBatch(1, "auto")
				task.wait(AUTO_LOOP_WAIT_SECONDS)
			else
				task.wait(IDLE_WAIT_SECONDS)
			end
		end
	end)

	return true, nil
end

function TuneMode.show(): (boolean, string?)
	if not _active then
		return false, "tune mode not running"
	end
	appendStatus("Tune state")
	if baselineSnapshotJson() ~= "" then
		UIState.appendLog("Tune baseline json: " .. baselineSnapshotJson())
	end
	if lastCompareJson() ~= "" then
		UIState.appendLog("Tune compare json: " .. lastCompareJson())
	end
	if promotionSnapshot() ~= "" then
		UIState.appendLog("Tune promote: " .. promotionSnapshot())
	end
	Tracer.log(
		string.format(
			"tune_show sector=%d mechanic=%s auto=%s run=%s candidate=%d bounds=%s attrs=%s baseline=%s compare=%s last=%s best=%s batch=%s best_batch=%s",
			_sectorId,
			tostring(_mechanic),
			tostring(_autoRun),
			tostring(_runInFlight),
			_candidateVersion,
			boundsSummary(),
			attrSummary(),
			baselineSnapshotJson(),
			lastCompareJson(),
			lastPassJson(),
			bestPassJson(),
			lastBatchJson(),
			bestBatchJson()
		)
	)
	syncTelemetry()
	return true, nil
end

function TuneMode.runAttempts(attemptCount: number): (boolean, string?)
	if not _active then
		return false, "tune mode not running"
	end
	if _autoRun then
		return false, "disable /tune auto before /tune run"
	end
	local requested = math.floor(attemptCount)
	if requested < 1 then
		return false, "run count must be at least 1"
	end
	local applied = math.clamp(requested, 1, MAX_RUN_ATTEMPTS)
	local ok, reason = runBatch(applied, "manual")
	if not ok then
		return false, reason
	end
	if applied ~= requested then
		UIState.appendLog(string.format("Tune run: using %d attempts (requested %d)", applied, requested))
	else
		UIState.appendLog(string.format("Tune run: x%d on candidate v%d", applied, _candidateVersion))
	end
	syncTelemetry()
	return true, nil
end

function TuneMode.compareBaseline(attemptCount: number): (boolean, string?)
	if not _active then
		return false, "tune mode not running"
	end
	if _autoRun then
		return false, "disable /tune auto before /tune compare"
	end
	local okMutable, reason = ensureMutableState()
	if not okMutable then
		return false, reason
	end
	if _mechanic == nil or _workingState == nil then
		return false, "tune mode not running"
	end

	local requested = math.floor(attemptCount)
	if requested < 1 then
		return false, "compare count must be at least 1"
	end
	local applied = math.clamp(requested, 1, MAX_RUN_ATTEMPTS)
	local token = _token
	local baselineState = cloneState(_baselineState or productionBaselineState(_mechanic))
	local candidateState = cloneState(_workingState)
	local candidateVersion = _candidateVersion
	local attrSnapshot = cloneTable(_attrOverrides)

	_runInFlight = true
	_lastResultText = string.format("compare queued x%d", applied)
	_lastFailureText = ""
	syncTelemetry()
	UIState.appendLog(string.format("Tune compare: baseline vs candidate v%d x%d", candidateVersion, applied))

	task.spawn(function()
		local acquired = false
		while token == _token and _active do
			if JobLock.tryAcquire() then
				acquired = true
				break
			end
			task.wait(IDLE_WAIT_SECONDS)
		end

		local comparison = nil
		local compareError = nil
		if acquired then
			local ok, result = pcall(function()
				return TuneExperiment.compareCandidates({
					{
						label = "production_baseline",
						passes = applied,
						state = baselineState,
						attr_overrides = {},
						clear_all_attrs = true,
					},
					{
						label = string.format("candidate_v%d", candidateVersion),
						passes = applied,
						state = candidateState,
						attr_overrides = attrSnapshot,
					},
				})
			end)
			JobLock.release()
			if ok then
				comparison = result
			else
				compareError = tostring(result)
			end
		elseif token == _token and _active then
			compareError = "compare could not acquire job lock"
		end

		_runInFlight = false

		if compareError ~= nil then
			_lastResultText = "compare error"
			_lastFailureText = compareError
			UIState.setError("tune compare error: " .. compareError)
			UIState.appendLog("Tune compare error: " .. compareError)
		elseif comparison ~= nil then
			_lastCompare = {
				requested_passes = applied,
				candidate_version = candidateVersion,
				heuristic_best = comparison.best and comparison.best.label or "",
				production_best = comparison.best_production and comparison.best_production.label or "",
				baseline = comparison.results[1],
				candidate = comparison.results[2],
				summary = comparison.comparison,
			}
			local summary = _lastCompare.summary or {}
			_lastResultText = string.format(
				"compare x%d heuristic=%s prod=%s",
				applied,
				tostring(summary.heuristic_winner or ""),
				tostring(summary.challenge_winner or "")
			)
			_lastFailureText = ""
			UIState.appendLog(
				string.format(
					"Tune compare done: dh=%.1f dp=%.1f winner=%s/%s",
					summary.heuristic_delta or 0,
					summary.challenge_delta or 0,
					tostring(summary.heuristic_winner or ""),
					tostring(summary.challenge_winner or "")
				)
			)
			Tracer.log(string.format("tune_compare sector=%d %s", _sectorId, lastCompareJson()))
		end

		applyState(_workingState)

		if _pendingStopFinalize then
			finaliseStop()
			return
		end
		if token ~= _token or not _active then
			return
		end

		UIState.setPhase("TuneMode", phaseLabelForMechanic())
		syncTelemetry()
	end)

	return true, nil
end

function TuneMode.promote(): (boolean, string?)
	local okMutable, reason = ensureMutableState()
	if not okMutable then
		return false, reason
	end
	if _mechanic == nil or _workingState == nil then
		return false, "tune mode not running"
	end

	_promotionSnapshot = HttpService:JSONEncode({
		sector_id = _sectorId,
		mechanic = _mechanic,
		candidate_version = _candidateVersion,
		state = {
			params = cloneTable(_workingState.params),
			pads = cloneTable(_workingState.pads),
		},
		attrs = cloneTable(_attrOverrides),
		baseline = if _baselineState ~= nil
			then {
				params = cloneTable(_baselineState.params),
				pads = cloneTable(_baselineState.pads),
			}
			else nil,
		last_batch = cloneTable(_lastBatch),
		best_batch = cloneTable(_bestBatch),
		compare = cloneTable(_lastCompare),
	})
	_lastResultText = string.format("promote snapshot v%d", _candidateVersion)
	_lastFailureText = ""
	UIState.appendLog("Tune promote: snapshot ready")
	Tracer.log(string.format("tune_promote sector=%d candidate=%d", _sectorId, _candidateVersion))
	syncTelemetry()
	return true, nil
end

function TuneMode.setAuto(enabled: boolean): (boolean, string?)
	if not _active then
		return false, "tune mode not running"
	end
	if _runInFlight and enabled == true then
		return false, "tune run in flight; try again shortly"
	end
	_autoRun = enabled == true
	if not _autoRun and _runInFlight then
		_lastResultText = "auto off queued"
		UIState.appendLog("Tune auto: off (queued after current run)")
	else
		_lastResultText = if _autoRun then "auto on" else stageLabel()
		UIState.appendLog("Tune auto: " .. (_autoRun and "on" or "off"))
	end
	_lastFailureText = ""
	syncTelemetry()
	return true, nil
end

function TuneMode.setLever(lever: string, value: number): (boolean, string?)
	local okMutable, reason = ensureMutableState()
	if not okMutable then
		return false, reason
	end
	if _mechanic == nil then
		return false, "tune mode not running"
	end
	local allowed = false
	for _, name in ipairs(LevelMappings.NUMERIC_LEVERS[_mechanic] or {}) do
		if name == lever then
			allowed = true
			break
		end
	end
	if not allowed then
		return false, "invalid tune lever for " .. tostring(_mechanic)
	end

	pauseAutoForStagedEdit()
	local applied, err = TuneLab.normalizeLever(_mechanic, lever, value, _workingState.params)
	if applied == nil then
		return false, err
	end
	local changed = _workingState.params[lever] ~= applied
	_workingState.params[lever] = applied
	if changed then
		markCandidateChanged()
	end
	syncTelemetry()
	if applied ~= value then
		UIState.appendLog(string.format("Tune set: %s=%s (requested %s)", lever, tostring(applied), tostring(value)))
	else
		UIState.appendLog(string.format("Tune set: %s=%s", lever, tostring(applied)))
	end
	return true, nil
end

function TuneMode.setPad(side: string, value: string): (boolean, string?)
	local okMutable, reason = ensureMutableState()
	if not okMutable then
		return false, reason
	end
	if side ~= "ingress" and side ~= "egress" then
		return false, "pad side must be ingress or egress"
	end
	local normalized = PadValueUtils.normalize(value)
	if not PadValueUtils.isValid(normalized) then
		return false, "invalid pad value"
	end
	pauseAutoForStagedEdit()
	local changed = _workingState.pads[side] ~= normalized
	_workingState.pads[side] = normalized
	if changed then
		markCandidateChanged()
	end
	syncTelemetry()
	UIState.appendLog(string.format("Tune pad: %s=%s", side, normalized))
	return true, nil
end

function TuneMode.setAttr(name: string, value: number): (boolean, string?)
	local okMutable, reason = ensureMutableState()
	if not okMutable then
		return false, reason
	end
	local spec = ATTR_SPECS[name]
	if spec == nil then
		return false, "unknown tune attr"
	end
	pauseAutoForStagedEdit()
	local applied = normalizeAttrValue(name, value)
	local previous = _attrOverrides[name]
	workspace:SetAttribute(spec.workspace_attr, applied)
	_attrOverrides[name] = applied
	if previous ~= applied then
		markCandidateChanged()
	end
	syncTelemetry()
	if applied ~= value then
		UIState.appendLog(string.format("Tune attr: %s=%s (requested %s)", name, tostring(applied), tostring(value)))
	else
		UIState.appendLog(string.format("Tune attr: %s=%s", name, tostring(applied)))
	end
	return true, nil
end

function TuneMode.reset(): (boolean, string?)
	local okMutable, reason = ensureMutableState()
	if not okMutable then
		return false, reason
	end
	if _mechanic == nil then
		return false, "tune mode not running"
	end
	pauseAutoForStagedEdit()
	_baselineState = cloneState(productionBaselineState(_mechanic))
	_workingState = cloneState(_baselineState)
	clearTuneAttrs()
	applyState(_workingState)
	markCandidateChanged()
	syncTelemetry()
	appendStatus("Tune reset")
	return true, nil
end

function TuneMode.revert(): (boolean, string?)
	local okMutable, reason = ensureMutableState()
	if not okMutable then
		return false, reason
	end
	pauseAutoForStagedEdit()
	local committed = cloneState(currentCommittedState())
	_workingState = cloneState(committed)
	_mechanic = committed.mechanic
	clearTuneAttrs()
	applyState(committed)
	markCandidateChanged()
	syncTelemetry()
	appendStatus("Tune reverted")
	return true, nil
end

function TuneMode.commit(): (boolean, string?)
	local okMutable, reason = ensureMutableState()
	if not okMutable then
		return false, reason
	end
	local committed = currentCommittedState()
	local nextState = cloneState(_workingState)
	nextState.version = committed.version + 1
	applyState(nextState)
	SectorRegistry.commit(nextState)
	UIState.setSectorMechanic(_sectorId, nextState.mechanic)
	_workingState = cloneState(nextState)
	_lastResultText = string.format("committed v%d", nextState.version)
	_lastFailureText = ""
	syncTelemetry()
	UIState.appendLog(string.format("Tune commit: sector %d v%d", _sectorId, nextState.version))
	Tracer.log(string.format("tune_commit sector=%d version=%d", _sectorId, nextState.version))
	return true, nil
end

function TuneMode.stop(): (boolean, string?)
	if not _active then
		return false, "tune mode not running"
	end
	_active = false
	_autoRun = false
	_token += 1
	if _runInFlight or JobLock.isHeld() then
		_pendingStopFinalize = true
		UIState.appendLog("Tune stop queued")
		syncTelemetry()
		return true, nil
	end
	finaliseStop()
	return true, nil
end

function TuneMode.supportedAttrs(): { string }
	local names = {}
	for name, _ in pairs(ATTR_SPECS) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

function TuneMode.bestPass()
	return if _bestPass ~= nil then compactPassRecord(_bestPass) else nil
end

function TuneMode.recentPasses()
	return cloneTable(_recentPasses)
end

return TuneMode
