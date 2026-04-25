--!strict

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

		local straights = 0
		local corners = 0
		local badSectors: { string } = {}
		for _, folder in ipairs(sectors) do
			local kind = folder:GetAttribute("SectorKind")
			if kind == "Straight" then
				straights += 1
			elseif kind == "Corner" then
				corners += 1
			end

			local anchor = folder:FindFirstChild("Anchor")
			local collision = folder:FindFirstChild("Collision")
			local visual = folder:FindFirstChild("Visual")
			local pads = folder:FindFirstChild("Pads")
			local collisionCount = collision and collision:IsA("Folder") and #collision:GetChildren() or -1
			local visualCount = visual and visual:IsA("Folder") and #visual:GetChildren() or -1
			if
				not (
					anchor
					and anchor:IsA("BasePart")
					and collision
					and collision:IsA("Folder")
					and visual
					and visual:IsA("Folder")
					and pads
					and pads:IsA("Folder")
					and collisionCount >= 1
					and visualCount >= 1
				)
			then
				table.insert(badSectors, folder.Name)
			end
		end

		T.expect("straight_count", straights == 6, "expected 6 straights, got " .. straights)
		T.expect("corner_count", corners == 4, "expected 4 corners, got " .. corners)
		T.expect("sector_parts", #badSectors == 0, "bad sectors: " .. table.concat(badSectors, ", "))
	end

	-- Car
	local car = workspace:FindFirstChild("VerifierCar")
	T.expect("car_spawned", car ~= nil and car:IsA("BasePart"), "VerifierCar not in workspace")
	if car and car:IsA("BasePart") then
		local y = car.Position.Y
		T.expect(
			"car_height",
			math.abs(y - CAR_RIDE_Y) < 1.0,
			string.format("car Y=%.2f, expected ~%.2f", y, CAR_RIDE_Y)
		)
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
	T.expect(
		"player_characters_disabled",
		Players.CharacterAutoLoads == false,
		"Players.CharacterAutoLoads should be false"
	)
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
	local lapTimeNumber = if type(lapTime) == "number" then lapTime else -1
	T.expect("baseline_lap_done", lapDone == true, "AutoTrack_BaselineLapDone not true (main not ready?)")
	T.expect(
		"baseline_lap_time",
		lapTimeNumber > 0 and lapTimeNumber < Constants.LAP_TIMEOUT,
		string.format("lap time %.2f out of range", lapTimeNumber)
	)
end

return TestPhase1
