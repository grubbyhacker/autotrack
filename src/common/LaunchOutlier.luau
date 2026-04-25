--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

export type LaunchMetrics = {
	hang_time: number?,
	airtime_distance: number?,
	target_airtime_distance: number?,
	vertical_displacement: number?,
	target_vertical_displacement: number?,
}

export type Classification = {
	detected: boolean,
	reasons: { string },
	hang_time: number,
	airtime_distance: number,
	vertical_displacement: number,
}

local LaunchOutlier = {}

local function numberOrZero(value: number?): number
	if type(value) == "number" then
		return value
	end
	return 0
end

function LaunchOutlier.classify(metrics: LaunchMetrics?): Classification
	local hangTime = numberOrZero(if metrics then metrics.hang_time else nil)
	local airtimeDistance = math.max(
		numberOrZero(if metrics then metrics.airtime_distance else nil),
		numberOrZero(if metrics then metrics.target_airtime_distance else nil)
	)
	local verticalDisplacement = math.max(
		numberOrZero(if metrics then metrics.vertical_displacement else nil),
		numberOrZero(if metrics then metrics.target_vertical_displacement else nil)
	)
	local reasons: { string } = {}

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

function LaunchOutlier.reasonSummary(classification: Classification?): string
	if not classification or #classification.reasons == 0 then
		return ""
	end
	return table.concat(classification.reasons, ",")
end

return LaunchOutlier
