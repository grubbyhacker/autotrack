--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local OrchestratorAgent = require(script.Parent.OrchestratorAgent)
local T = require(script.Parent.TestUtils)
local UIState = require(script.Parent.UIState)

local TestPhase26 = {}

type AttributeValue = boolean | number | string
type AttributeSnapshot = { [string]: AttributeValue }

local ATTRS = {
	"baseline_lap_time",
	"last_lap_time",
	"last_run_scope",
	"slowdown_ratio",
	"committed_lap_time",
	"committed_slowdown_ratio",
	"last_score_sector",
	"last_score_total",
	"last_score_air",
	"last_score_lateral",
	"last_score_near_miss",
	"last_score_time_cost",
	"last_score_budget_used",
	"last_score_over_budget",
	"sector_3_committed_score",
	"track_score_total",
	"track_score_count",
	"track_budget_used",
	"track_budget_headroom",
	"track_over_budget",
}

local function approxEq(a: number, b: number, epsilon: number?): boolean
	local tol = epsilon or 1e-4
	return math.abs((a or 0) - (b or 0)) <= tol
end

local function numberAttr(folder: Instance, name: string, fallback: number): number
	local value = folder:GetAttribute(name)
	return if type(value) == "number" then value else fallback
end

local function boolAttr(folder: Instance, name: string): boolean
	return folder:GetAttribute(name) == true
end

local function snapshotAttrs(folder: Instance): AttributeSnapshot
	local snapshot: AttributeSnapshot = {}
	for _, name in ipairs(ATTRS) do
		local value = folder:GetAttribute(name)
		if type(value) == "boolean" or type(value) == "number" or type(value) == "string" then
			snapshot[name] = value
		end
	end
	return snapshot
end

local function restoreAttrs(folder: Instance, snapshot: AttributeSnapshot)
	for _, name in ipairs(ATTRS) do
		folder:SetAttribute(name, snapshot[name])
	end
end

local function testCommittedLapAttrsOnlyAdvanceOnCommittedPublish(folder: Instance)
	folder:SetAttribute("committed_lap_time", 31.25)
	folder:SetAttribute("committed_slowdown_ratio", 1.19)

	UIState.publishAttemptResult({
		metrics = {
			lap_time = 8.75,
			slowdown_ratio = 0.55,
		},
	}, "isolated_sector")

	T.expect(
		"phase26_isolated_publish_does_not_touch_committed_lap",
		approxEq(numberAttr(folder, "committed_lap_time", -1), 31.25)
			and approxEq(numberAttr(folder, "committed_slowdown_ratio", -1), 1.19),
		string.format(
			"committed_lap_time=%s committed_slowdown_ratio=%s",
			tostring(folder:GetAttribute("committed_lap_time")),
			tostring(folder:GetAttribute("committed_slowdown_ratio"))
		)
	)

	UIState.publishCommittedLap({
		metrics = {
			lap_time = 26.4,
			slowdown_ratio = 1.07,
		},
	})

	T.expect(
		"phase26_committed_publish_updates_committed_lap_attrs",
		approxEq(numberAttr(folder, "committed_lap_time", -1), 26.4)
			and approxEq(numberAttr(folder, "committed_slowdown_ratio", -1), 1.07),
		string.format(
			"committed_lap_time=%s committed_slowdown_ratio=%s",
			tostring(folder:GetAttribute("committed_lap_time")),
			tostring(folder:GetAttribute("committed_slowdown_ratio"))
		)
	)
end

local function testIsolatedPublishCannotOverwriteCommittedDisplaySource(folder: Instance)
	UIState.publishCommittedLap({
		metrics = {
			lap_time = 24.8,
			slowdown_ratio = 1.02,
		},
	})
	UIState.publishAttemptResult({
		metrics = {
			lap_time = 6.1,
			slowdown_ratio = 0.41,
		},
	}, "isolated_sector")

	T.expect(
		"phase26_isolated_publish_keeps_committed_last_percent_source",
		approxEq(numberAttr(folder, "committed_lap_time", -1), 24.8)
			and approxEq(numberAttr(folder, "committed_slowdown_ratio", -1), 1.02),
		string.format(
			"committed_lap_time=%s committed_slowdown_ratio=%s",
			tostring(folder:GetAttribute("committed_lap_time")),
			tostring(folder:GetAttribute("committed_slowdown_ratio"))
		)
	)
end

local function testCommittedSectorScorePublishing(folder: Instance)
	UIState.publishScore(3, {
		total = 44.3,
		air = 16.2,
		lateral = 9.4,
		near_miss = 10.1,
		time_cost = 8.6,
		budget_used = 0.37,
		over_budget = false,
	})

	T.expect(
		"phase26_publish_score_sets_sector_committed_score_attr",
		numberAttr(folder, "last_score_sector", 0) == 3
			and approxEq(numberAttr(folder, "last_score_total", 0), 44.3)
			and approxEq(numberAttr(folder, "sector_3_committed_score", -1), 44.3),
		string.format(
			"last_score_sector=%s last_score_total=%s sector_3_committed_score=%s",
			tostring(folder:GetAttribute("last_score_sector")),
			tostring(folder:GetAttribute("last_score_total")),
			tostring(folder:GetAttribute("sector_3_committed_score"))
		)
	)
end

local function testTrackBudgetSummaryRemainsCommitAuthoritative(folder: Instance)
	local trackIntent = {
		target_total_score = 92.5,
		target_budget_used = 0.46,
		diversity_pressure = {},
	}
	local scoresBySector = {
		[2] = 38.2,
		[7] = 54.3,
	}
	local slowdownRatio = 1 + Constants.ENDURANCE_LAP_TIME_BUDGET_RATIO + 0.03
	local summary = OrchestratorAgent._trackSummaryForHUD(trackIntent, slowdownRatio, scoresBySector)

	T.expect(
		"phase26_track_summary_uses_committed_track_intent",
		approxEq(summary.total, 92.5)
			and summary.sector_count == 2
			and approxEq(summary.budget_used, 0.46)
			and approxEq(summary.budget_headroom, 0.54)
			and summary.over_budget == true,
		(
			string.format(
				"total=%s count=%s budget_used=%s headroom=%s over=%s",
				tostring(summary.total),
				tostring(summary.sector_count),
				tostring(summary.budget_used),
				tostring(summary.budget_headroom),
				tostring(summary.over_budget)
			)
		)
	)

	UIState.publishTrackScore(
		summary.total,
		summary.sector_count,
		summary.budget_used,
		summary.budget_headroom,
		summary.over_budget
	)
	UIState.publishAttemptResult({
		metrics = {
			lap_time = 5.8,
			slowdown_ratio = 0.35,
		},
	}, "isolated_sector")

	T.expect(
		"phase26_isolated_publish_does_not_overwrite_track_summary_attrs",
		approxEq(numberAttr(folder, "track_score_total", 0), 92.5)
			and numberAttr(folder, "track_score_count", 0) == 2
			and approxEq(numberAttr(folder, "track_budget_used", 0), 0.46)
			and approxEq(numberAttr(folder, "track_budget_headroom", 0), 0.54)
			and boolAttr(folder, "track_over_budget"),
		(
			string.format(
				"track_score_total=%s count=%s budget_used=%s headroom=%s over=%s",
				tostring(folder:GetAttribute("track_score_total")),
				tostring(folder:GetAttribute("track_score_count")),
				tostring(folder:GetAttribute("track_budget_used")),
				tostring(folder:GetAttribute("track_budget_headroom")),
				tostring(folder:GetAttribute("track_over_budget"))
			)
		)
	)
end

function TestPhase26.run()
	local folder = UIState.getStateFolder()
	local snapshot = snapshotAttrs(folder)

	local ok, err = pcall(function()
		testCommittedLapAttrsOnlyAdvanceOnCommittedPublish(folder)
		testIsolatedPublishCannotOverwriteCommittedDisplaySource(folder)
		testCommittedSectorScorePublishing(folder)
		testTrackBudgetSummaryRemainsCommitAuthoritative(folder)
	end)

	restoreAttrs(folder, snapshot)
	if not ok then
		error(err)
	end
end

return TestPhase26
