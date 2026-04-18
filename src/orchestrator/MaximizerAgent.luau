-- MaximizerAgent.luau
-- Phase 11c — the "uber agent" campaign. Walks a preset plan of sector/mechanic
-- pairs, submits each as an `extreme` request through JobRunner, and tallies
-- the final aggregate ChallengeScore once the pass is complete.
--
-- Intentionally minimal:
--   • No custom proposer. Every commit comes from the normal JobRunner path
--     (propose → verify → repair → Stage B challenge-up).
--   • No mid-run mechanic selection. The plan is fixed; future 11c-next can
--     swap in per-sector lever search.
--   • Runs off the main coroutine. JobRunner.submit is synchronous inside a
--     coroutine and MaximizerAgent.run is expected to be called from one.
--
-- plans/phase11.md §3.5

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local ChallengeScore = require(script.Parent.Parent.Integrity.ChallengeScore)
local UIState = require(script.Parent.UIState)
local Tracer = require(script.Parent.Tracer)

local MaximizerAgent = {}

-- Fixed v1 plan. Each editable straight gets one extreme request.
-- Sectors 2/7 get jumps (hang-time reward). 3/9 get crests (airtime near-miss).
-- 4/8 get chicanes (lateral occupancy). The request text must parse cleanly
-- through RequestParser — single sector, single supported mechanic, `extreme`
-- qualifier to opt into Stage B.
local PLAN = {
	{ sector = 2, request = "add an extreme tall jump in sector 2" },
	{ sector = 3, request = "add an extreme deep crest in sector 3" },
	{ sector = 4, request = "add an extreme tight chicane in sector 4" },
	{ sector = 7, request = "add an extreme tall jump in sector 7" },
	{ sector = 8, request = "add an extreme tight chicane in sector 8" },
	{ sector = 9, request = "add an extreme deep crest in sector 9" },
}

local _active = false

function MaximizerAgent.isActive(): boolean
	return _active
end

-- Wait for the caller's busy signal to clear. The submit function returns
-- synchronously, but commit dwell and Stage B can leave the lock held briefly
-- afterward. This polls via the caller's isBusy probe.
local function waitForIdle(isBusy: () -> boolean, timeoutSeconds: number): boolean
	local deadline = os.clock() + timeoutSeconds
	while os.clock() < deadline do
		if not isBusy() then return true end
		task.wait(0.1)
	end
	return not isBusy()
end

-- args = {
--   submit    : (string) -> (boolean, string?),    -- JobRunner.submit
--   isBusy    : () -> boolean,                     -- JobRunner.isBusy
--   isCameraDemoActive : () -> boolean,            -- CameraDemo.isActive
-- }
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

	_active = true
	UIState.setPhase("Maximize", "Maximizer campaign starting")
	UIState.appendLog(string.format("Maximizer: %d-step plan begins", #PLAN))
	Tracer.log(string.format("maximize_start steps=%d", #PLAN))

	local committedScores = {}
	local committedCount = 0
	local failedCount = 0

	for index, step in ipairs(PLAN) do
		UIState.setPhase("Maximize", string.format("Maximize step %d/%d", index, #PLAN))
		UIState.appendLog(string.format("Maximize %d/%d: %s", index, #PLAN, step.request))

		local ok, reason = args.submit(step.request)
		if not ok then
			UIState.appendLog(string.format("Maximize step %d skipped: %s", index, tostring(reason)))
			Tracer.log(string.format("maximize_skip step=%d sector=%d reason=%s",
				index, step.sector, tostring(reason)))
			failedCount += 1
		else
			-- Worst-case: baseline-sized lap * (1 + CHALLENGE_UP_ROUNDS) + repair attempts + margin.
			local budget = Constants.MAX_REPAIR_ATTEMPTS * 45
				+ Constants.CHALLENGE_UP_ROUNDS * 45
				+ 30
			if not waitForIdle(args.isBusy, budget) then
				UIState.appendLog(string.format("Maximize step %d never settled; stopping", index))
				Tracer.log(string.format("maximize_abort step=%d sector=%d reason=timeout",
					index, step.sector))
				_active = false
				UIState.setPhase("Maximize", "Maximizer aborted")
				return false, "maximizer step timed out"
			end
		end

		local committed = SectorRegistry.getCommitted(step.sector)
		if committed and committed.mechanic then
			committedCount += 1
			-- Re-use the last-published score from UIState attributes. We
			-- cannot recompute here because RunMetrics are not retained.
			local folder = ReplicatedStorage:FindFirstChild("AutoTrackUIState")
			if folder and folder:GetAttribute("last_score_sector") == step.sector then
				table.insert(committedScores, {
					total       = folder:GetAttribute("last_score_total") or 0,
					air         = folder:GetAttribute("last_score_air") or 0,
					lateral     = folder:GetAttribute("last_score_lateral") or 0,
					near_miss   = folder:GetAttribute("last_score_near_miss") or 0,
					time_cost   = folder:GetAttribute("last_score_time_cost") or 0,
					budget_used = folder:GetAttribute("last_score_budget_used") or 0,
					over_budget = folder:GetAttribute("last_score_over_budget") == true,
				})
			end
		end
	end

	local agg = ChallengeScore.aggregate(committedScores)
	UIState.setPhase("Maximize", "Maximizer done")
	UIState.appendLog(string.format(
		"Maximize done: %d committed, %d skipped, aggregate %.1f%s",
		committedCount, failedCount, agg.total,
		if agg.any_over_budget then " (OVER BUDGET)" else ""
	))
	Tracer.log(string.format(
		"maximize_end committed=%d skipped=%d aggregate=%.2f over_budget=%s",
		committedCount, failedCount, agg.total, tostring(agg.any_over_budget)
	))

	_active = false
	return true, nil
end

return MaximizerAgent
