local HUDRegistry = require(script.Parent.HUDRegistry)

local StatsPanel = {}

local COMPASS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

local function refs()
	return HUDRegistry.get()
end

local function formatSeconds(seconds: number): string
	if seconds == nil or seconds < 0 then
		return "--"
	end
	return ("%.2fs"):format(seconds)
end

local function compassPoint(deg: number): string
	local idx = math.floor((deg + 22.5) / 45) % 8
	return COMPASS[idx + 1]
end

local function budgetBar(used: number): string
	local BAR_LEN = 8
	local filled = math.clamp(math.floor(used * BAR_LEN + 0.5), 0, BAR_LEN)
	return string.rep("█", filled) .. string.rep("░", BAR_LEN - filled)
end

function StatsPanel.setBaseline(seconds: number)
	refs().baselineLabel.Text = ("Baseline  %s"):format(formatSeconds(seconds))
end

function StatsPanel.setLastLapTime(seconds: number)
	refs().lastLapLabel.Text = ("Last Lap  %s"):format(formatSeconds(seconds))
end

function StatsPanel.setSlowdown(ratio: number)
	local percent = math.floor(((ratio or 1) - 1) * 100 + 0.5)
	refs().slowdownLabel.Text = ("Slowdown  %+d%%"):format(percent)
end

function StatsPanel.setCurrentSpeed(speed: number, commandedSpeed: number?, targetSpeed: number?)
	refs().speedLabel.Text = ("Speed  %.1f  Cmd %.1f  Tgt %.1f"):format(
		speed or 0,
		commandedSpeed or 0,
		targetSpeed or 0
	)
end

function StatsPanel.setHeading(deg: number)
	refs().headingLabel.Text = ("Heading  %s %d°"):format(compassPoint(deg or 0), math.floor(deg or 0))
end

function StatsPanel.setPitch(deg: number)
	refs().pitchLabel.Text = ("Pitch  %+.0f°"):format(deg or 0)
end

function StatsPanel.setScore(
	sectorId: number,
	total: number,
	air: number,
	lateral: number,
	edge: number,
	cost: number,
	overBudget: boolean,
	trackTotal: number,
	trackCount: number,
	trackBudgetUsed: number,
	trackBudgetHeadroom: number,
	trackOverBudget: boolean
)
	local label = refs().scoreLabel

	if (not sectorId or sectorId == 0) and (not trackCount or trackCount == 0) then
		label.Text = "Score  --\nAir --  Edge --\nLat --  Cost --\nTrack --\nBudget ░░░░░░░░"
		label.TextColor3 = refs().colors.text
		return
	end

	local sectorText = if sectorId and sectorId > 0
		then ("S%d  %.1f"):format(sectorId, total or 0)
		else "S--"
	local usedPercent = math.floor((trackBudgetUsed or 0) * 100 + 0.5)
	local bar = budgetBar(trackBudgetUsed or 0)
	local budgetFlag = if trackOverBudget then " !" else ""

	if trackCount and trackCount > 0 then
		label.Text = ("Score  %s%s\nAir %.1f  Edge %.1f\nLat %.1f  Cost %.1f\nTrack %.1f (%d)\nBudget %s %d%%"):format(
			sectorText,
			if overBudget then " !" else "",
			air or 0,
			edge or 0,
			lateral or 0,
			cost or 0,
			trackTotal or 0,
			trackCount,
			bar .. budgetFlag,
			usedPercent
		)
	else
		label.Text = ("Score  %s%s\nAir %.1f  Edge %.1f\nLat %.1f  Cost %.1f\nTrack --\nBudget ░░░░░░░░"):format(
			sectorText,
			if overBudget then " !" else "",
			air or 0,
			edge or 0,
			lateral or 0,
			cost or 0
		)
	end

	label.TextColor3 = if overBudget or trackOverBudget then refs().colors.danger else refs().colors.text
end

return StatsPanel
