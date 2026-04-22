-- CrestDipIntegrity.luau
-- Evaluates whether a completed run satisfies CrestDip mechanic integrity.
-- prd_plan.md §11.4, §15.7, Phase 5; curvature + airtime-cap added in Phase 9

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local RuntimeTuning = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("RuntimeTuning"))

type RunMetrics = Types.RunMetrics
type SectorState = Types.SectorState

local CrestDipIntegrity = {}

function CrestDipIntegrity.preflight(
	state: SectorState
): (boolean, { string })
	local hints: { string } = {}
	local p = state.params
	local h = p.height_or_depth or 0
	local L = p.sector_length or 0

	if math.abs(h) < RuntimeTuning.numberAttr(
		"AutoTrack_CrestDipMinVerticalDisplacement",
		Constants.CRESTDIP_MIN_VERTICAL_DISPLACEMENT
	) then
		table.insert(hints, "vertical displacement below minimum")
	end

	-- Curvature approximation for the cosine profile: peak |d²y/dz²| ∝ |h|/L².
	-- Tuned against CRESTDIP_MIN_CURVATURE in Constants.
	if L > 0 then
		local curvature = math.abs(h) / (L * L)
		if curvature < RuntimeTuning.numberAttr(
			"AutoTrack_CrestDipMinCurvature",
			Constants.CRESTDIP_MIN_CURVATURE
		) then
			table.insert(hints, "crest curvature too gentle")
		end
	end

	return #hints == 0, hints
end

function CrestDipIntegrity.evaluateRuntime(
	metrics: RunMetrics
): (boolean, { string })
	local hints: { string } = {}
	local verticalDisplacement = metrics.target_vertical_displacement or metrics.vertical_displacement
	local airborne = if metrics.target_airborne ~= nil then metrics.target_airborne else metrics.airborne
	local airtimeDistance = if metrics.target_reacquire_distance ~= nil
		then metrics.target_reacquire_distance
		else metrics.target_airtime_distance or metrics.airtime_distance or 0
	local reacquired = if metrics.target_reacquired ~= nil then metrics.target_reacquired else metrics.reacquired
	local apexMinSpeed = metrics.target_apex_min_speed or 0
	local exitAngularSpeed = metrics.target_exit_angular_speed or 0
	local exitVerticalSpeed = metrics.target_exit_vertical_speed or 0
	local minVerticalDisplacement = RuntimeTuning.numberAttr(
		"AutoTrack_CrestDipMinVerticalDisplacement",
		Constants.CRESTDIP_MIN_VERTICAL_DISPLACEMENT
	) + RuntimeTuning.numberAttr(
		"AutoTrack_CrestDipComfortVerticalMargin",
		Constants.CRESTDIP_COMFORT_VERTICAL_MARGIN
	)
	local minApexSpeed = RuntimeTuning.numberAttr(
		"AutoTrack_CrestDipApexMinSpeed",
		Constants.CRESTDIP_APEX_MIN_SPEED
	) + RuntimeTuning.numberAttr(
		"AutoTrack_CrestDipComfortApexSpeedMargin",
		Constants.CRESTDIP_COMFORT_APEX_SPEED_MARGIN
	)
	local maxAirtimeDistance = math.max(0, RuntimeTuning.numberAttr(
		"AutoTrack_CrestDipMaxAirtimeDistance",
		Constants.CRESTDIP_MAX_AIRTIME_DISTANCE
	) - RuntimeTuning.numberAttr(
		"AutoTrack_CrestDipComfortAirtimeMargin",
		Constants.CRESTDIP_COMFORT_AIRTIME_MARGIN
	))

	if verticalDisplacement < minVerticalDisplacement then
		table.insert(hints, "runtime vertical displacement too small")
	end

	if apexMinSpeed > 0 and apexMinSpeed < minApexSpeed then
		table.insert(hints, "crest apex speed too low")
	end

	-- Airtime cap — only enforced if the car actually left the surface.
	-- PRD §4.3: CrestDip has no airborne requirement, so skip when never airborne.
	if airborne and airtimeDistance > maxAirtimeDistance then
		table.insert(hints, "airborne too long after liftoff")
	end

	if not reacquired then
		table.insert(hints, "car did not reacquire semi-rail before sector exit")
	end
	if exitAngularSpeed > RuntimeTuning.numberAttr(
		"AutoTrack_CrestDipComfortExitMaxAngularSpeed",
		Constants.CRESTDIP_COMFORT_EXIT_MAX_ANGULAR_SPEED
	) then
		table.insert(hints, "crest exit angular speed too high")
	end
	if exitVerticalSpeed > RuntimeTuning.numberAttr(
		"AutoTrack_CrestDipComfortExitMaxVerticalSpeed",
		Constants.CRESTDIP_COMFORT_EXIT_MAX_VERTICAL_SPEED
	) then
		table.insert(hints, "crest exit vertical speed too high")
	end

	return #hints == 0, hints
end

function CrestDipIntegrity.evaluate(
	state: SectorState,
	metrics: RunMetrics
): (boolean, { string })
	local hints: { string } = {}
	local preflightOk, preflightHints = CrestDipIntegrity.preflight(state)
	local runtimeOk, runtimeHints = CrestDipIntegrity.evaluateRuntime(metrics)

	if not preflightOk then
		for _, hint in ipairs(preflightHints) do
			table.insert(hints, hint)
		end
	end
	if not runtimeOk then
		for _, hint in ipairs(runtimeHints) do
			table.insert(hints, hint)
		end
	end

	return #hints == 0, hints
end

return CrestDipIntegrity
