local HUDRegistry = require(script.Parent.HUDRegistry)

local StatsPanel = {}

local function refs()
	return HUDRegistry.get()
end

local function formatSeconds(seconds: number): string
	if seconds == nil or seconds < 0 then
		return "--"
	end
	return ("%.2fs"):format(seconds)
end

function StatsPanel.setBaseline(seconds: number)
	refs().baselineLabel.Text = ("Baseline\n%s"):format(formatSeconds(seconds))
end

function StatsPanel.setLastLapTime(seconds: number)
	refs().lastLapLabel.Text = ("Last Lap\n%s"):format(formatSeconds(seconds))
end

function StatsPanel.setSlowdown(ratio: number)
	local percent = math.floor(((ratio or 1) - 1) * 100 + 0.5)
	refs().slowdownLabel.Text = ("Slowdown\n%+d%%"):format(percent)
end

function StatsPanel.setCurrentSpeed(speed: number)
	refs().currentSpeedLabel.Text = ("Current Speed\n%.1f"):format(speed or 0)
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
		label.Text = "Score\n--\nAir --  Edge --\nLat --  Cost --"
		label.TextColor3 = refs().colors.text
		return
	end

	local sectorText = if sectorId and sectorId > 0
		then ("S%d %.1f"):format(sectorId, total or 0)
		else "S--"
	local usedPercent = math.floor((trackBudgetUsed or 0) * 100 + 0.5)
	local headroomPercent = math.floor((trackBudgetHeadroom or 0) * 100 + 0.5)

	if trackCount and trackCount > 0 then
		local budgetFlag = if trackOverBudget then " !" else ""
		label.Text = ("Score %s\nAir %.1f  Edge %.1f\nLat %.1f  Cost %.1f\nTrack %.1f  B%d/%d%%%s"):format(
			sectorText,
			air or 0,
			edge or 0,
			lateral or 0,
			cost or 0,
			trackTotal or 0,
			usedPercent,
			headroomPercent,
			budgetFlag
		)
	else
		local sectorFlag = if overBudget then " !" else ""
		label.Text = ("Score %s%s\nAir %.1f  Edge %.1f\nLat %.1f  Cost %.1f"):format(
			sectorText,
			sectorFlag,
			air or 0,
			edge or 0,
			lateral or 0,
			cost or 0
		)
	end

	label.TextColor3 = if overBudget or trackOverBudget then refs().colors.danger else refs().colors.text
end

return StatsPanel
