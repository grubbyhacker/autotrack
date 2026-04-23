local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

local LaunchOutlier = {}

local function numberOrZero(value): number
	if type(value) == "number" then
		return value
	end
	return 0
end

function LaunchOutlier.classify(metrics)
	local hangTime = numberOrZero(metrics and metrics.hang_time)
	local airtimeDistance = math.max(
		numberOrZero(metrics and metrics.airtime_distance),
		numberOrZero(metrics and metrics.target_airtime_distance)
	)
	local verticalDisplacement = math.max(
		numberOrZero(metrics and metrics.vertical_displacement),
		numberOrZero(metrics and metrics.target_vertical_displacement)
	)
	local reasons = {}

	if hangTime >= Constants.RAMPJUMP_LAUNCH_OUTLIER_HANG_TIME then
		table.insert(reasons, "hang_time")
	end
	if
		airtimeDistance >= Constants.RAMPJUMP_LAUNCH_OUTLIER_AIRTIME_DISTANCE
		and hangTime >= (Constants.RAMPJUMP_LAUNCH_OUTLIER_HANG_TIME * 0.65)
	then
		table.insert(reasons, "airtime_distance")
	end
	if
		verticalDisplacement >= Constants.RAMPJUMP_LAUNCH_OUTLIER_VERTICAL_DISPLACEMENT
		and hangTime >= (Constants.RAMPJUMP_LAUNCH_OUTLIER_HANG_TIME * 0.65)
	then
		table.insert(reasons, "vertical_displacement")
	end

	return {
		detected = #reasons > 0,
		reasons = reasons,
		hang_time = hangTime,
		airtime_distance = airtimeDistance,
		vertical_displacement = verticalDisplacement,
	}
end

function LaunchOutlier.reasonSummary(classification): string
	local reasons = if classification and type(classification.reasons) == "table" then classification.reasons else {}
	if #reasons == 0 then
		return ""
	end
	return table.concat(reasons, ",")
end

return LaunchOutlier
