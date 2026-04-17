-- TestPhase4_5.luau
-- Verifies Phase 4.5 deliverables: arc-based corner waypoints and corner speed reduction.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local T = require(script.Parent.TestUtils)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)

local TestPhase4_5 = {}

local CORNER_SECTOR_IDS = { 1, 5, 6, 10 }
local A_STRAIGHT_ID = 2
local ARC_TOLERANCE = 0.05  -- studs

local function waitForBaseline(): (boolean, number?)
	local deadline = os.clock() + 45
	while os.clock() < deadline do
		local lapDone = workspace:GetAttribute("AutoTrack_BaselineLapDone")
		local lapTime = workspace:GetAttribute("AutoTrack_BaselineLapTime")
		if lapDone ~= nil and lapTime ~= nil then
			return lapDone == true, lapTime
		end
		task.wait(0.25)
	end
	return false, nil
end

local function ensureBaselineOrAbort(): boolean
	if workspace:GetAttribute("AutoTrack_BootBaselineSkipped") == true then
		print("[TEST] Proceeding without boot baseline (SkipBootBaseline mode)")
		return true
	end
	local baselineOk, baselineTime = waitForBaseline()
	T.expect(
		"phase4_5_baseline_complete",
		baselineOk and type(baselineTime) == "number" and baselineTime > 0,
		"baseline lap did not complete before phase4_5 tests"
	)
	return baselineOk == true
end

-- ── Geometric tests (no lap required, compatible with SkipBootBaseline) ──────

function TestPhase4_5.runGeometry()
	local sectors = TrackGenerator.generate()
	local waypoints, waypointSectors, sectorKinds = TrackGenerator.getLapPath(sectors)

	-- sectorKinds labels
	local cornersLabeled = sectorKinds[1] == "Corner" and sectorKinds[5] == "Corner"
		and sectorKinds[6] == "Corner" and sectorKinds[10] == "Corner"
	T.expect("sectorKinds_corners_labeled", cornersLabeled,
		"expected corner sectors 1,5,6,10 labeled Corner")

	local straightsLabeled = sectorKinds[2] == "Straight" and sectorKinds[3] == "Straight"
		and sectorKinds[4] == "Straight" and sectorKinds[7] == "Straight"
		and sectorKinds[8] == "Straight" and sectorKinds[9] == "Straight"
	T.expect("sectorKinds_straights_labeled", straightsLabeled,
		"expected straight sectors 2-4,7-9 labeled Straight")

	-- Build per-sector waypoint lists and sector lookup
	local sectorWpts: { [number]: { CFrame } } = {}
	for i, wpt in ipairs(waypoints) do
		local sid = waypointSectors[i]
		if not sectorWpts[sid] then sectorWpts[sid] = {} end
		table.insert(sectorWpts[sid], wpt)
	end

	local sectorById = {}
	for _, sector in ipairs(sectors) do
		sectorById[sector.id] = sector
	end

	local up = Vector3.new(0, 1, 0)
	local R = Constants.CORNER_RADIUS + Constants.TRACK_WIDTH * 0.5
	local N = Constants.CORNER_ARC_SAMPLES

	local allCountsOk = true
	local allOnArc = true
	local countErrors = {}
	local arcErrors = {}

	for _, cid in ipairs(CORNER_SECTOR_IDS) do
		local sector = sectorById[cid]
		local wpts = sectorWpts[cid] or {}
		local count = #wpts

		if count ~= N then
			allCountsOk = false
			table.insert(countErrors, string.format("corner%d: got %d want %d", cid, count, N))
		end

		-- Arc center is computed from entry position and look direction (Y component will be TRACK_Y).
		-- Waypoints are at CAR_RIDE_Y. Compare XZ distance only.
		local arcCenter = sector.entry.Position + sector.entry.LookVector:Cross(up) * R
		for _, wpt in ipairs(wpts) do
			local dx = wpt.Position.X - arcCenter.X
			local dz = wpt.Position.Z - arcCenter.Z
			local dist = math.sqrt(dx * dx + dz * dz)
			if math.abs(dist - R) > ARC_TOLERANCE then
				allOnArc = false
				table.insert(arcErrors, string.format(
					"corner%d @(%.1f,%.1f) dist=%.3f want %.3f",
					cid, wpt.Position.X, wpt.Position.Z, dist, R
				))
			end
		end
	end

	T.expect("corner_waypoint_count", allCountsOk, table.concat(countErrors, "; "))
	T.expect("corner_waypoints_on_arc", allOnArc, table.concat(arcErrors, "; "))
end

-- ── Lap test ──────────────────────────────────────────────────────────────────

function TestPhase4_5.runLap()
	if not ensureBaselineOrAbort() then return end

	local sectors = TrackGenerator.generate()
	local waypoints, waypointSectors, sectorKinds = TrackGenerator.getLapPath(sectors)
	VerifierCar.reset(TrackGenerator.canonicalStart())
	local car = VerifierCar.getPart()
	local result = VerifierController.runLap(car, waypoints, waypointSectors, sectorKinds, nil)

	T.expect(
		"corner_arc_lap_completes",
		result.success == true,
		"lap failed: " .. tostring(result.failure and result.failure.type)
	)
end

-- ── Speed test ────────────────────────────────────────────────────────────────

function TestPhase4_5.runSpeed()
	if not ensureBaselineOrAbort() then return end

	local sectors = TrackGenerator.generate()
	local waypoints, waypointSectors, sectorKinds = TrackGenerator.getLapPath(sectors)
	VerifierCar.reset(TrackGenerator.canonicalStart())
	local car = VerifierCar.getPart()

	local sectorExitSpeeds: { [number]: number } = {}
	local function onSectorChange(id: number, entering: boolean)
		if not entering then
			sectorExitSpeeds[id] = car.AssemblyLinearVelocity.Magnitude
		end
	end

	local result = VerifierController.runLap(car, waypoints, waypointSectors, sectorKinds, onSectorChange)
	T.expect(
		"speed_test_lap_completes",
		result.success == true,
		"speed test lap failed: " .. tostring(result.failure and result.failure.type)
	)

	local cornerSpeed = sectorExitSpeeds[CORNER_SECTOR_IDS[1]] or 0
	local straightSpeed = sectorExitSpeeds[A_STRAIGHT_ID] or 0

	T.expect("corner_exit_speed_recorded", cornerSpeed > 0,
		string.format("no exit speed recorded for corner sector %d", CORNER_SECTOR_IDS[1]))
	T.expect("straight_exit_speed_recorded", straightSpeed > 0,
		string.format("no exit speed recorded for straight sector %d", A_STRAIGHT_ID))
	T.expect(
		"corner_speed_lower_than_straight",
		cornerSpeed < straightSpeed,
		string.format("corner exit speed %.2f should be < straight exit speed %.2f", cornerSpeed, straightSpeed)
	)
end

-- ── Master entry point ────────────────────────────────────────────────────────

function TestPhase4_5.run()
	TestPhase4_5.runGeometry()
	TestPhase4_5.runLap()
	TestPhase4_5.runSpeed()
end

return TestPhase4_5
