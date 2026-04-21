-- TestPhase4_5.luau
-- Verifies Phase 4.5 deliverables: arc-based corner waypoints and corner speed reduction.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local T = require(script.Parent.TestUtils)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local CornerPath = require(script.Parent.Parent.Track.CornerPath)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)

local TestPhase4_5 = {}

local CORNER_SECTOR_IDS = { 1, 5, 6, 10 }
local A_STRAIGHT_ID = 2
local ENTRY_ALIGNMENT_TOLERANCE = 0.98
local EXIT_ALIGNMENT_TOLERANCE = 0.98
local MAX_CORNER_CONTAINMENT = Constants.OFF_TRACK_FAILURE_DISTANCE * 0.75
local MAX_CORNER_BODY_CONTAINMENT = Constants.FRONT_BODY_CONTAINMENT_DISTANCE * 0.95

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

	-- Build per-sector waypoint lists, excluding the lap-closing waypoint (always last).
	-- The closing waypoint duplicates sector 1's entry and must not inflate the arc count.
	local sectorWpts: { [number]: { CFrame } } = {}
	for i = 1, #waypoints - 1 do
		local sid = waypointSectors[i]
		if not sectorWpts[sid] then sectorWpts[sid] = {} end
		table.insert(sectorWpts[sid], waypoints[i])
	end

	local sectorById = {}
	for _, sector in ipairs(sectors) do
		sectorById[sector.id] = sector
	end

	local allCountsOk = true
	local countErrors = {}
	local endpointErrors = {}
	local alignmentErrors = {}

	for _, cid in ipairs(CORNER_SECTOR_IDS) do
		local sector = sectorById[cid]
		local wpts = sectorWpts[cid] or {}
		local count = #wpts
		local expected = #CornerPath.buildWorldCenterlinePoints(
			sector.entry,
			sector.exit,
			sector.entryShoulderLength,
			sector.exitShoulderLength
		)

		if count ~= expected then
			allCountsOk = false
			table.insert(countErrors, string.format("corner%d: got %d want %d", cid, count, expected))
		end

		if count >= 2 then
			local first = wpts[1]
			local second = wpts[2]
			local last = wpts[count]
			local penultimate = wpts[count - 1]
			local firstDelta = Vector3.new(first.Position.X - sector.entry.Position.X, 0, first.Position.Z - sector.entry.Position.Z)
			local lastDelta = Vector3.new(last.Position.X - sector.exit.Position.X, 0, last.Position.Z - sector.exit.Position.Z)
			if firstDelta.Magnitude > 0.05
				or lastDelta.Magnitude > 0.05 then
				table.insert(endpointErrors, string.format(
					"corner%d endpoints off: start=%.3f end=%.3f",
					cid,
					firstDelta.Magnitude,
					lastDelta.Magnitude
				))
			end
			local entryDir = (second.Position - first.Position).Unit
			local exitDir = (last.Position - penultimate.Position).Unit
			if entryDir:Dot(sector.entry.LookVector) < ENTRY_ALIGNMENT_TOLERANCE
				or exitDir:Dot(sector.exit.LookVector) < EXIT_ALIGNMENT_TOLERANCE then
				table.insert(alignmentErrors, string.format(
					"corner%d alignment bad: entry=%.3f exit=%.3f",
					cid,
					entryDir:Dot(sector.entry.LookVector),
					exitDir:Dot(sector.exit.LookVector)
				))
			end
		end
	end

	T.expect("corner_waypoint_count", allCountsOk, table.concat(countErrors, "; "))
	T.expect("corner_waypoints_match_sector_endpoints", #endpointErrors == 0, table.concat(endpointErrors, "; "))
	T.expect("corner_waypoints_align_with_entry_exit", #alignmentErrors == 0, table.concat(alignmentErrors, "; "))
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

	local sectorEntrySpeeds: { [number]: number } = {}
	local sectorExitSpeeds: { [number]: number } = {}
	local sector2EntryLocalX = nil
	local sector2 = nil
	for _, sector in ipairs(sectors) do
		if sector.id == A_STRAIGHT_ID then
			sector2 = sector
			break
		end
	end
	assert(sector2 ~= nil, "sector 2 meta missing")
	local function onSectorChange(id: number, entering: boolean)
		if entering then
			sectorEntrySpeeds[id] = car.AssemblyLinearVelocity.Magnitude
			if id == A_STRAIGHT_ID then
				sector2EntryLocalX = sector2.entry:PointToObjectSpace(car.Position).X
			end
		end
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
	local sector5ExitSpeed = sectorExitSpeeds[5] or 0
	local sector6EntrySpeed = sectorEntrySpeeds[6] or 0

	T.expect("corner_exit_speed_recorded", cornerSpeed > 0,
		string.format("no exit speed recorded for corner sector %d", CORNER_SECTOR_IDS[1]))
	T.expect("straight_exit_speed_recorded", straightSpeed > 0,
		string.format("no exit speed recorded for straight sector %d", A_STRAIGHT_ID))
	T.expect(
		"corner_speed_lower_than_straight",
		cornerSpeed < straightSpeed,
		string.format("corner exit speed %.2f should be < straight exit speed %.2f", cornerSpeed, straightSpeed)
	)
	T.expect(
		"sector2_entry_centered_after_sector1_corner",
		type(sector2EntryLocalX) == "number" and math.abs(sector2EntryLocalX) <= 4.0,
		string.format("sector 2 entry localX %.2f should stay near centerline", sector2EntryLocalX or math.huge)
	)
	T.expect(
		"corner_exit_speed_uses_exit_shoulder",
		cornerSpeed > Constants.CAR_TARGET_SPEED * Constants.CORNER_SPEED_FACTOR
			and cornerSpeed < Constants.CAR_TARGET_SPEED,
		string.format(
			"corner exit speed %.2f should be between corner cap %.2f and straight %.2f",
			cornerSpeed,
			Constants.CAR_TARGET_SPEED * Constants.CORNER_SPEED_FACTOR,
			Constants.CAR_TARGET_SPEED
		)
	)
	T.expect(
		"consecutive_corner_handoff_stays_slow",
		sector5ExitSpeed > 0
			and sector6EntrySpeed > 0
			and sector5ExitSpeed <= Constants.CAR_TARGET_SPEED * (Constants.CORNER_SPEED_FACTOR + 0.12)
			and sector6EntrySpeed <= sector5ExitSpeed + 6,
		string.format(
			"sector5 exit %.2f and sector6 entry %.2f should stay near continuous corner speed",
			sector5ExitSpeed,
			sector6EntrySpeed
		)
	)
	T.expect(
		"baseline_corner_lateral_error_stays_on_road",
		(result.metrics.lateral_error or math.huge) <= Constants.OFF_TRACK_FAILURE_DISTANCE * 0.85,
		string.format(
			"baseline lateral error %.2f exceeded containment budget %.2f",
			result.metrics.lateral_error or math.huge,
			Constants.OFF_TRACK_FAILURE_DISTANCE * 0.85
		)
	)
	local perCornerOk = true
	local perCornerMessages = {}
	for _, sectorId in ipairs(CORNER_SECTOR_IDS) do
		local peak = result.metrics.sector_peak_centerline_distance and result.metrics.sector_peak_centerline_distance[sectorId] or math.huge
		local bodyPeak = result.metrics.sector_peak_body_distance and result.metrics.sector_peak_body_distance[sectorId] or math.huge
		if peak > MAX_CORNER_CONTAINMENT or bodyPeak > MAX_CORNER_BODY_CONTAINMENT then
			perCornerOk = false
			table.insert(perCornerMessages, string.format(
				"sector %d center %.2f front %.2f body %.2f signed %.2f progress %.2f",
				sectorId,
				peak,
				(result.metrics.sector_peak_front_distance and result.metrics.sector_peak_front_distance[sectorId]) or 0,
				bodyPeak,
				(result.metrics.sector_peak_signed_lateral and result.metrics.sector_peak_signed_lateral[sectorId]) or 0,
				(result.metrics.sector_peak_progress and result.metrics.sector_peak_progress[sectorId]) or 0
			))
		end
	end
	T.expect(
		"baseline_each_corner_stays_contained",
		perCornerOk,
		table.concat(perCornerMessages, " | ")
	)
end

-- ── Master entry point ────────────────────────────────────────────────────────

function TestPhase4_5.run()
	TestPhase4_5.runGeometry()
	TestPhase4_5.runLap()
	TestPhase4_5.runSpeed()
end

return TestPhase4_5
