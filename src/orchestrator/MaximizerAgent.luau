-- MaximizerAgent.luau
-- Phase 11c campaign runner for `/demo maximize`.
--
-- Responsibilities:
--   1. Walk a fixed extreme-request plan across all editable straights.
--   2. Retain the committed score for each sector.
--   3. Run a final full-track budget probe.
--   4. Evict the lowest-value sectors until the lap is back under budget.
--   5. Publish aggregate campaign score + budget usage into UIState.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local SectorApplier = require(script.Parent.Parent.Track.SectorApplier)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)
local JobLock = require(script.Parent.JobLock)
local RuntimeContext = require(script.Parent.RuntimeContext)
local UIState = require(script.Parent.UIState)
local Tracer = require(script.Parent.Tracer)

local MaximizerAgent = {}

local PLAN = {
	{ sector = 2, request = "add an extreme tall jump in sector 2" },
	{ sector = 3, request = "add an extreme deep crest in sector 3" },
	{ sector = 4, request = "add an extreme tight chicane in sector 4" },
	{ sector = 7, request = "add an extreme tall jump in sector 7" },
	{ sector = 8, request = "add an extreme long wide chicane in sector 8" },
	{ sector = 9, request = "add an extreme deep crest in sector 9" },
}

local _active = false

local function cloneScore(score)
	return {
		total = score.total,
		air = score.air,
		lateral = score.lateral,
		near_miss = score.near_miss,
		time_cost = score.time_cost,
		budget_used = score.budget_used,
		over_budget = score.over_budget,
	}
end

local function scoreSnapshotForSector(sectorId: number)
	local folder = ReplicatedStorage:FindFirstChild("AutoTrackUIState")
	if not folder or folder:GetAttribute("last_score_sector") ~= sectorId then
		return nil
	end

	return {
		total = folder:GetAttribute("last_score_total") or 0,
		air = folder:GetAttribute("last_score_air") or 0,
		lateral = folder:GetAttribute("last_score_lateral") or 0,
		near_miss = folder:GetAttribute("last_score_near_miss") or 0,
		time_cost = folder:GetAttribute("last_score_time_cost") or 0,
		budget_used = folder:GetAttribute("last_score_budget_used") or 0,
		over_budget = folder:GetAttribute("last_score_over_budget") == true,
	}
end

local function budgetUsedFromSlowdown(slowdownRatio: number): number
	if Constants.CHALLENGE_BUDGET_RATIO <= 0 then
		return 0
	end
	return math.max(0, slowdownRatio - 1) / Constants.CHALLENGE_BUDGET_RATIO
end

local function summarizeCampaign(scoresBySector, slowdownRatio: number, probeSucceeded: boolean)
	local total = 0
	local count = 0
	for _, score in pairs(scoresBySector) do
		total += score.total
		count += 1
	end

	local rawBudgetUsed = budgetUsedFromSlowdown(slowdownRatio)
	local budgetUsed = math.clamp(rawBudgetUsed, 0, 1)
	local overBudget = (not probeSucceeded) or slowdownRatio > (1 + Constants.CHALLENGE_BUDGET_RATIO)

	return {
		total = total,
		sector_count = count,
		budget_used = budgetUsed,
		budget_headroom = math.max(0, 1 - budgetUsed),
		over_budget = overBudget,
		raw_budget_used = rawBudgetUsed,
	}
end

local function probeFailureDetail(probe): string
	if probe == nil or probe.failure == nil or probe.failure.detail == nil or probe.failure.detail == "" then
		return "-"
	end
	return probe.failure.detail
end

local function selectEvictionSector(scoresBySector): (number?, any?)
	local lowestSectorId = nil
	local lowestScore = nil
	local count = 0

	for sectorId, score in pairs(scoresBySector) do
		if score.total > 0 then
			count += 1
			if lowestScore == nil
				or score.total < lowestScore.total
				or (score.total == lowestScore.total and sectorId < lowestSectorId) then
				lowestSectorId = sectorId
				lowestScore = score
			end
		end
	end

	if count <= Constants.MAXIMIZER_MIN_RETAINED_SECTORS then
		return nil, nil
	end

	return lowestSectorId, lowestScore
end

local function runBudgetProbe()
	local sectors = RuntimeContext.getSectors()
	local overrides = {}
	for _, state in ipairs(SectorRegistry.getStraights()) do
		if state.mechanic ~= nil then
			overrides[state.sector_id] = state
		end
	end

	local waypoints, waypointSectors, sectorKinds = TrackGenerator.getLapPath(sectors, overrides)
	VerifierCar.reset(RuntimeContext.getCanonicalStart())

	return VerifierController.runLap(
		RuntimeContext.getCar(),
		waypoints,
		waypointSectors,
		sectorKinds,
		function(id: number, entering: boolean)
			if entering then
				UIState.setCurrentSector(id)
			end
		end,
		nil,
		nil,
		nil
	)
end

local function evictSector(sectorId: number)
	local current = SectorRegistry.getCommitted(sectorId)
	assert(current ~= nil, "cannot evict unknown sector " .. tostring(sectorId))

	local sectorMeta = RuntimeContext.getSectorById(sectorId)
	local nextState = {
		sector_id = sectorId,
		mechanic = nil,
		params = {},
		pads = {
			ingress = "None",
			egress = "None",
		},
		version = current.version + 1,
	}

	SectorRegistry.commit(nextState)
	SectorApplier.apply(nextState, sectorMeta.entry, sectorMeta.exit)
	UIState.setSectorMechanic(sectorId, nil)

	return nextState
end

local function trackIsFlatCommitted(): boolean
	for _, state in ipairs(SectorRegistry.getStraights()) do
		if state.mechanic ~= nil then
			return false
		end
		if state.pads.ingress ~= "None" or state.pads.egress ~= "None" then
			return false
		end
	end
	return true
end

local function ensureBaseline(): (boolean, string?)
	if workspace:GetAttribute("AutoTrack_BaselineLapDone") == true then
		return true, nil
	end
	if not trackIsFlatCommitted() then
		return false, "baseline missing on modified track"
	end
	if not JobLock.tryAcquire() then
		return false, "track busy while recording baseline"
	end

	UIState.setPhase("BootBaseline", "Recording baseline lap...")
	UIState.appendLog("Baseline lap started on demand")
	Tracer.log("lap_start")

	local sectors = RuntimeContext.getSectors()
	local waypoints, waypointSectors, sectorKinds = TrackGenerator.getLapPath(sectors)
	local car = RuntimeContext.getCar()
	VerifierCar.reset(RuntimeContext.getCanonicalStart())

	local ok, result = pcall(function()
		return VerifierController.runLap(
			car,
			waypoints,
			waypointSectors,
			sectorKinds,
			function(id: number, entering: boolean)
				if entering then
					UIState.setCurrentSector(id)
					Tracer.log(string.format("sector_enter %d speed=%.1f", id, car.AssemblyLinearVelocity.Magnitude))
				else
					Tracer.log(string.format("sector_exit %d speed=%.1f", id, car.AssemblyLinearVelocity.Magnitude))
				end
			end
		)
	end)
	JobLock.release()

	if not ok then
		return false, tostring(result)
	end
	if not result.success then
		workspace:SetAttribute("AutoTrack_BaselineLapDone", false)
		workspace:SetAttribute("AutoTrack_BaselineLapTime", -1)
		UIState.setBaselineLapTime(-1)
		RuntimeContext.setBaselineLapTime(-1)
		return false, "baseline lap failed: " .. tostring(result.failure and result.failure.type or "unknown")
	end

	local lapTime = result.metrics.lap_time
	workspace:SetAttribute("AutoTrack_BaselineLapDone", true)
	workspace:SetAttribute("AutoTrack_BaselineLapTime", lapTime)
	UIState.setBaselineLapTime(lapTime)
	RuntimeContext.setBaselineLapTime(lapTime)
	UIState.appendLog(string.format("Baseline lap complete: %.2fs", lapTime))
	Tracer.log(string.format("lap_complete %.2f", lapTime))
	return true, nil
end

function MaximizerAgent.isActive(): boolean
	return _active
end

function MaximizerAgent.run(args): (boolean, string?)
	if _active then
		return false, "maximizer already running"
	end
	if args.isCameraDemoActive and args.isCameraDemoActive() then
		return false, "camera demo running; toggle it off before /demo maximize"
	end
	if args.isBusy() then
		return false, "track is busy; try again shortly"
	end
	assert(RuntimeContext.isReady(), "maximizer requires runtime context")

	_active = true
	workspace:SetAttribute("AutoTrack_MaximizeCampaignActive", true)
	UIState.resetTrackScore()

	local ok, result, reason = pcall(function()
		UIState.setPhase("Maximize", "Maximizer campaign starting")
		UIState.appendLog(string.format("Maximizer: %d-step plan begins", #PLAN))
		Tracer.log(string.format("maximize_start steps=%d", #PLAN))

		local baselineOk, baselineErr = ensureBaseline()
		if not baselineOk then
			return false, baselineErr
		end

		local scoresBySector = {}
		local committedCount = 0
		local skippedCount = 0
		local evictedCount = 0

		for index, step in ipairs(PLAN) do
			UIState.setPhase("Maximize", string.format("Maximize step %d/%d", index, #PLAN))
			UIState.appendLog(string.format("Maximize %d/%d: %s", index, #PLAN, step.request))

			local submitOk, submitReason = args.submit(step.request)
			if not submitOk then
				skippedCount += 1
				UIState.appendLog(string.format("Maximize step %d skipped: %s", index, tostring(submitReason)))
				Tracer.log(string.format("maximize_skip step=%d sector=%d reason=%s",
					index, step.sector, tostring(submitReason)))
			else
				local committed = SectorRegistry.getCommitted(step.sector)
				if committed and committed.mechanic ~= nil then
					committedCount += 1
					local score = scoreSnapshotForSector(step.sector)
					if score then
						scoresBySector[step.sector] = cloneScore(score)
						local summary = summarizeCampaign(
							scoresBySector,
							1 + math.min(1, score.budget_used) * Constants.CHALLENGE_BUDGET_RATIO,
							not score.over_budget
						)
						UIState.publishTrackScore(
							summary.total,
							summary.sector_count,
							summary.budget_used,
							summary.budget_headroom,
							summary.over_budget
						)
						UIState.appendLog(string.format(
							"Sector %d locked %.1f; running total %.1f",
							step.sector,
							score.total,
							summary.total
						))
					else
						UIState.appendLog(string.format("Sector %d locked without score snapshot", step.sector))
					end
				end
			end
		end

		UIState.setPhase("Maximize", "Running full-track budget probe")
		UIState.appendLog("Running final budget probe")
		local probe = runBudgetProbe()
		local summary = summarizeCampaign(
			scoresBySector,
			probe.metrics and probe.metrics.slowdown_ratio or 1,
			probe.success == true
		)
		UIState.publishTrackScore(
			summary.total,
			summary.sector_count,
			summary.budget_used,
			summary.budget_headroom,
			summary.over_budget
		)
		Tracer.log(string.format(
			"maximize_probe success=%s slowdown=%.3f total=%.2f count=%d failure_type=%s failure_sector=%s failure_detail=%s",
			tostring(probe.success == true),
			probe.metrics and probe.metrics.slowdown_ratio or -1,
			summary.total,
			summary.sector_count,
			tostring(probe.failure and probe.failure.type or "-"),
			tostring(probe.failure and probe.failure.sector_id or "-"),
			probeFailureDetail(probe)
		))

		while summary.over_budget do
			local evictSectorId, evictScore = selectEvictionSector(scoresBySector)
			if evictSectorId == nil or evictScore == nil then
				break
			end

			UIState.setPhase("Maximize", "Evicting low-value sector")
			UIState.appendLog(string.format(
				"Evicting sector %d (score %.1f) to recover budget",
				evictSectorId,
				evictScore.total
			))
			Tracer.log(string.format(
				"maximize_evict sector=%d score=%.2f",
				evictSectorId,
				evictScore.total
			))
			evictSector(evictSectorId)
			scoresBySector[evictSectorId] = nil
			evictedCount += 1

			probe = runBudgetProbe()
			summary = summarizeCampaign(
				scoresBySector,
				probe.metrics and probe.metrics.slowdown_ratio or 1,
				probe.success == true
			)
			UIState.publishTrackScore(
				summary.total,
				summary.sector_count,
				summary.budget_used,
				summary.budget_headroom,
				summary.over_budget
			)
		end

		UIState.setPhase("Maximize", "Maximizer done")
		UIState.appendLog(string.format(
			"Maximize done: %d committed, %d skipped, %d evicted, total %.1f",
			committedCount,
			skippedCount,
			evictedCount,
			summary.total
		))
		UIState.appendLog(string.format(
			"Final budget %.0f%% used%s",
			summary.budget_used * 100,
			if summary.over_budget then " (OVER)" else ""
		))
		Tracer.log(string.format(
			"maximize_end committed=%d skipped=%d evicted=%d aggregate=%.2f over_budget=%s budget_used=%.2f",
			committedCount,
			skippedCount,
			evictedCount,
			summary.total,
			tostring(summary.over_budget),
			summary.raw_budget_used
		))

		if summary.over_budget then
			return false, "maximizer could not recover budget"
		end
		return true, nil
	end)

	workspace:SetAttribute("AutoTrack_MaximizeCampaignActive", false)
	_active = false

	if not ok then
		local err = tostring(result)
		UIState.setPhase("Maximize", "Maximizer failed")
		UIState.setError(err)
		Tracer.log("maximize_error " .. err)
		return false, err
	end

	return result, reason
end

-- Test hooks for unit coverage of the pure campaign heuristics.
function MaximizerAgent._summarizeCampaign(scoresBySector, slowdownRatio: number, probeSucceeded: boolean)
	return summarizeCampaign(scoresBySector, slowdownRatio, probeSucceeded)
end

function MaximizerAgent._selectEvictionSector(scoresBySector)
	return selectEvictionSector(scoresBySector)
end

function MaximizerAgent._plan()
	return PLAN
end

return MaximizerAgent
