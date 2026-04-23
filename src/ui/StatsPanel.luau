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

function StatsPanel.setBaseline(seconds: number)
	refs().baselineLabel.Text = ("Base %s"):format(formatSeconds(seconds))
end

function StatsPanel.setLastLapTime(seconds: number)
	refs().lastLapLabel.Text = ("Last %s"):format(formatSeconds(seconds))
end

function StatsPanel.setSlowdown(ratio: number)
	if ratio == nil or ratio <= 0 then
		refs().slowdownLabel.Text = "% --"
		return
	end
	local percent = math.floor((ratio - 1) * 100 + 0.5)
	refs().slowdownLabel.Text = ("%% %+d%%"):format(percent)
end

function StatsPanel.setCurrentSpeed(speed: number, _commandedSpeed: number?, _targetSpeed: number?)
	refs().speedValueLabel.Text = string.format("%5.1f", speed or 0)
end

function StatsPanel.setHeading(deg: number)
	refs().headingValueLabel.Text = string.format("%2s %3d°", compassPoint(deg or 0), math.floor(deg or 0))
end

function StatsPanel.setPitch(deg: number)
	refs().pitchValueLabel.Text = string.format("%+4.0f°", deg or 0)
end

function StatsPanel.setScore(
	_sectorId: number,
	_total: number,
	_air: number,
	_lateral: number,
	_edge: number,
	_cost: number,
	_overBudget: boolean,
	trackTotal: number,
	trackCount: number,
	trackBudgetUsed: number,
	_trackBudgetHeadroom: number,
	trackOverBudget: boolean
)
	local label = refs().scoreLabel

	if not trackCount or trackCount <= 0 then
		label.Text = table.concat({
			alignMetric("Track", "--"),
			alignMetric("Budget", "--"),
		}, "\n")
		label.TextColor3 = refs().colors.text
		return
	end

	local usedPercent = math.floor((trackBudgetUsed or 0) * 100 + 0.5)
	local budgetState = if trackOverBudget then "OVER" else "OK"
	label.Text = table.concat({
		alignMetric("Track", string.format("%4.1f (%d)", trackTotal or 0, trackCount)),
		alignMetric("Budget", string.format("%3d%% · %s", usedPercent, budgetState)),
	}, "\n")
	label.TextColor3 = if trackOverBudget then refs().colors.danger else refs().colors.text
end

return StatsPanel
