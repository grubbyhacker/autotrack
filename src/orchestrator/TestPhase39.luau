--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local LLMConfig = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LLMConfig"))
local RuntimeTuning = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("RuntimeTuning"))
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local CrestDipPath = require(script.Parent.Parent.Mechanics.CrestDipPath)
local CornerPath = require(script.Parent.Parent.Track.CornerPath)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local JobLock = require(script.Parent.JobLock)
local TestSuiteRunner = require(script.Parent.TestSuiteRunner)
local Tracer = require(script.Parent.Tracer)
local ReacquireDetector = require(script.Parent.Parent.Verifier.ReacquireDetector)
local T = require(script.Parent.TestUtils)

type SectorState = Types.SectorState

local TestPhase39 = {}

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-3
end

local function samePosition(a: Vector3, b: Vector3): boolean
	return near(a.X, b.X) and near(a.Y, b.Y) and near(a.Z, b.Z)
end

local function testRuntimeTuning()
	local attrName = "AutoTrack_Phase39RuntimeNumber"
	local stringAttrName = "AutoTrack_Phase39RuntimeString"
	local oldNumber = workspace:GetAttribute(attrName)
	local oldString = workspace:GetAttribute(stringAttrName)

	workspace:SetAttribute(attrName, nil)
	workspace:SetAttribute(stringAttrName, nil)
	local numberFallback = RuntimeTuning.numberAttr(attrName, 17)
	local stringFallback = RuntimeTuning.stringAttr(stringAttrName, "fallback")

	workspace:SetAttribute(attrName, 42)
	workspace:SetAttribute(stringAttrName, "configured")
	local numberConfigured = RuntimeTuning.numberAttr(attrName, 17)
	local stringConfigured = RuntimeTuning.stringAttr(stringAttrName, "fallback")

	workspace:SetAttribute(attrName, oldNumber)
	workspace:SetAttribute(stringAttrName, oldString)

	T.expect(
		"phase39_runtime_tuning_reads_typed_workspace_attrs",
		numberFallback == 17
			and stringFallback == "fallback"
			and numberConfigured == 42
			and stringConfigured == "configured"
	)
end

local function testLockTraceAndRunner()
	JobLock.release()
	local firstAcquire = JobLock.tryAcquire()
	local secondAcquire = JobLock.tryAcquire()
	local heldAfterAcquire = JobLock.isHeld()
	JobLock.release()
	local heldAfterRelease = JobLock.isHeld()

	Tracer.clear()
	Tracer.log("phase39_alpha")
	Tracer.log("phase39_beta")
	local log = Tracer.getLog()
	local traced = #log == 2 and log[1] == "phase39_alpha" and log[2] == "phase39_beta"
	Tracer.clear()

	TestSuiteRunner.setRunner(function(suite: string)
		return {
			status = "passed",
			pass_count = if suite == "phase39_probe" then 1 else 0,
			fail_count = 0,
			error_count = 0,
			message = nil,
			lines = { suite },
		}
	end)
	local configured = TestSuiteRunner.isConfigured()
	local snapshot = TestSuiteRunner.runSuite("phase39_probe")
	TestSuiteRunner.setRunner(nil)

	T.expect(
		"phase39_lock_trace_runner_helpers_hold_contracts",
		firstAcquire
			and not secondAcquire
			and heldAfterAcquire
			and not heldAfterRelease
			and traced
			and configured
			and snapshot ~= nil
			and snapshot.pass_count == 1
	)
end

local function testReacquireAndPaths()
	local airDistance = ReacquireDetector.airDistanceSince(Vector3.new(0, 0, 0), Vector3.new(3, 4, 12))
	local crestPoints = CrestDipPath.buildLocalCenterlinePoints(8, 28)
	local cornerEntry = CFrame.lookAt(Vector3.new(0, 0, 0), Vector3.new(0, 0, 1))
	local cornerExit = CFrame.lookAt(Vector3.new(20, 0, 20), Vector3.new(21, 0, 20))
	local cornerPoints = CornerPath.buildWorldCenterlinePoints(cornerEntry, cornerExit, 4, 4, 7, 4)

	T.expect(
		"phase39_reacquire_and_path_helpers_are_deterministic",
		near(airDistance, 13)
			and #crestPoints > 4
			and samePosition(crestPoints[1], Vector3.new(0, 0, 0))
			and samePosition(crestPoints[#crestPoints], Vector3.new(0, 0, Constants.STRAIGHT_LENGTH))
			and #cornerPoints > 4
			and samePosition(cornerPoints[1], cornerEntry.Position)
			and samePosition(cornerPoints[#cornerPoints], cornerExit.Position)
	)
end

local function testConfigAndRegistry()
	LLMConfig.setEnabled(false)
	LLMConfig.setModel("heuristic")
	local initial = LLMConfig.get()
	LLMConfig.cycleModel(1)
	local cycled = LLMConfig.get()
	LLMConfig.setModel("not-a-real-model")
	local afterUnknown = LLMConfig.get()
	LLMConfig.setModel("heuristic")

	SectorRegistry.init(6)
	local initialState = SectorRegistry.getCommitted(3)
	local committedState: SectorState = {
		sector_id = 3,
		mechanic = "CrestDip",
		params = {
			height_or_depth = 9,
			radius = 18,
			sector_length = 28,
		},
		pads = {
			ingress = "None",
			egress = "Boost10",
		},
		version = 2,
	}
	SectorRegistry.commit(committedState)
	local fetched = SectorRegistry.get(3)
	local states = SectorRegistry.getStraights()

	T.expect(
		"phase39_config_and_registry_keep_public_shapes",
		initial.modelId == "heuristic"
			and cycled.modelId ~= "heuristic"
			and afterUnknown.modelId == cycled.modelId
			and initialState ~= nil
			and initialState.mechanic == nil
			and fetched == committedState
			and #states == 6
			and SectorRegistry.count() == 6
	)
end

function TestPhase39.run()
	testRuntimeTuning()
	testLockTraceAndRunner()
	testReacquireAndPaths()
	testConfigAndRegistry()
end

return TestPhase39
