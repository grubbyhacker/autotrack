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

return StatsPanel
