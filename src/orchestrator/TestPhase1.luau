-- TestPhase1.luau
-- Verifies Phase 1 deliverables: track geometry, car spawn height,
-- sector registry state, job lock, and baseline lap completion.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local JobLock = require(script.Parent.JobLock)
local T = require(script.Parent.TestUtils)

local CAR_RIDE_Y = Constants.TRACK_THICKNESS + Constants.CAR_HEIGHT * 0.5

local TestPhase1 = {}

function TestPhase1.run()
	-- Track geometry
	local track = workspace:FindFirstChild("Track")
	T.expect("track_exists", track ~= nil and track:IsA("Folder"), "workspace.Track not found")

	if track then
		local sectors = track:GetChildren()
		T.expect("track_sector_count", #sectors == 10, "expected 10 sectors, got " .. #sectors)

		local straights, corners, badParts = 0, 0, {}
		for _, folder in ipairs(sectors) do
			local kind = folder:GetAttribute("SectorKind") -- set on the part, not folder
			-- SectorKind attribute is on the part inside the folder
			local part = folder:FindFirstChildWhichIsA("BasePart")
			if part then
				local k = part:GetAttribute("SectorKind")
				if k == "Straight" then straights += 1
				elseif k == "Corner" then corners += 1
				end
				local partCount = #folder:GetChildren()
				if partCount ~= 1 then
					table.insert(badParts, folder.Name .. "(" .. partCount .. ")")
				end
			else
				table.insert(badParts, folder.Name .. "(no part)")
			end
		end

		T.expect("straight_count", straights == 6, "expected 6 straights, got " .. straights)
		T.expect("corner_count", corners == 4, "expected 4 corners, got " .. corners)
		T.expect("sector_parts", #badParts == 0, "bad sectors: " .. table.concat(badParts, ", "))
	end

	-- Car
	local car = workspace:FindFirstChild("VerifierCar")
	T.expect("car_spawned", car ~= nil, "VerifierCar not in workspace")
	if car then
		local y = car.Position.Y
		T.expect("car_height", math.abs(y - CAR_RIDE_Y) < 1.0,
			string.format("car Y=%.2f, expected ~%.2f", y, CAR_RIDE_Y))
	end

	-- Sector registry
	local count = SectorRegistry.count()
	T.expect("registry_count", count == 6, "expected 6 straights, got " .. count)

	local allFlat = true
	for _, state in ipairs(SectorRegistry.getStraights()) do
		if state.mechanic ~= nil then
			allFlat = false
			break
		end
	end
	T.expect("registry_flat", allFlat, "some sectors have non-nil mechanic at init")

	-- Job lock
	T.expect("job_lock_free", not JobLock.isHeld(), "job lock still held after baseline lap")

	-- Player model
	T.expect("player_characters_disabled", Players.CharacterAutoLoads == false, "Players.CharacterAutoLoads should be false")
	local hasCharacter = false
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character ~= nil then
			hasCharacter = true
			break
		end
	end
	T.expect("player_character_absent", hasCharacter == false, "player character should not exist in spectator mode")

	-- Baseline lap result (written by Main.server.luau)
	local lapDone = workspace:GetAttribute("AutoTrack_BaselineLapDone")
	local lapTime = workspace:GetAttribute("AutoTrack_BaselineLapTime")
	T.expect("baseline_lap_done", lapDone == true, "AutoTrack_BaselineLapDone not true (main not ready?)")
	T.expect("baseline_lap_time",
		type(lapTime) == "number" and lapTime > 0 and lapTime < Constants.LAP_TIMEOUT,
		string.format("lap time %.2f out of range", lapTime or -1))
end

return TestPhase1
