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

local function alignMetric(name: string, value: string): string
	return string.format("%-6s %7s", name, value)
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
	refs().baselineLabel.Text = ("Base %s"):format(formatSeconds(seconds))
end

function StatsPanel.setLastLapTime(seconds: number)
	refs().lastLapLabel.Text = ("Last %s"):format(formatSeconds(seconds))
end

function StatsPanel.setSlowdown(ratio: number)
	local percent = math.floor(((ratio or 1) - 1) * 100 + 0.5)
	refs().slowdownLabel.Text = ("%+d%%"):format(percent)
end

function StatsPanel.setCurrentSpeed(speed: number, commandedSpeed: number?, targetSpeed: number?)
	refs().speedValueLabel.Text = string.format("%5.1f", speed or 0)
end

function StatsPanel.setHeading(deg: number)
	refs().headingValueLabel.Text = string.format("%2s %3d°", compassPoint(deg or 0), math.floor(deg or 0))
end

function StatsPanel.setPitch(deg: number)
	refs().pitchValueLabel.Text = string.format("%+4.0f°", deg or 0)
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
		label.Text = table.concat({
			alignMetric("Score", "--"),
			alignMetric("Air", "--"),
			alignMetric("Edge", "--"),
			alignMetric("Lat", "--"),
			alignMetric("Cost", "--"),
			alignMetric("Track", "--"),
			"Budget ░░░░░░░░",
		}, "\n")
		label.TextColor3 = refs().colors.text
		return
	end

	local sectorText = if sectorId and sectorId > 0
		then string.format("S%-2d %4.1f%s", sectorId, total or 0, if overBudget then "!" else "")
		else "S--"
	local usedPercent = math.floor((trackBudgetUsed or 0) * 100 + 0.5)
	local bar = budgetBar(trackBudgetUsed or 0)
	local budgetFlag = if trackOverBudget then " !" else ""

	if trackCount and trackCount > 0 then
		label.Text = table.concat({
			alignMetric("Score", sectorText),
			alignMetric("Air", string.format("%4.1f", air or 0)),
			alignMetric("Edge", string.format("%4.1f", edge or 0)),
			alignMetric("Lat", string.format("%4.1f", lateral or 0)),
			alignMetric("Cost", string.format("%4.1f", cost or 0)),
			alignMetric("Track", string.format("%4.1f (%d)", trackTotal or 0, trackCount)),
			string.format("Budget %s %3d%%%s", bar, usedPercent, budgetFlag),
		}, "\n")
	else
		label.Text = table.concat({
			alignMetric("Score", sectorText),
			alignMetric("Air", string.format("%4.1f", air or 0)),
			alignMetric("Edge", string.format("%4.1f", edge or 0)),
			alignMetric("Lat", string.format("%4.1f", lateral or 0)),
			alignMetric("Cost", string.format("%4.1f", cost or 0)),
			alignMetric("Track", "--"),
			"Budget ░░░░░░░░",
		}, "\n")
	end

	label.TextColor3 = if overBudget or trackOverBudget then refs().colors.danger else refs().colors.text
end

return StatsPanel
