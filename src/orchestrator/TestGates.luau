local TestGates = {}

function TestGates.runRefactorFast()
	local TestBootSmoke = require(script.Parent.TestBootSmoke)
	local TestPhase4_5 = require(script.Parent.TestPhase4_5)
	local TestPhase5 = require(script.Parent.TestPhase5)
	local TestPhase6 = require(script.Parent.TestPhase6)
	local TestPhase9 = require(script.Parent.TestPhase9)
	local TestPhase11 = require(script.Parent.TestPhase11)
	local TestPhase13 = require(script.Parent.TestPhase13)
	local TestPhase14 = require(script.Parent.TestPhase14)
	local TestPhase14_5 = require(script.Parent.TestPhase14_5)
	local TestPhase19 = require(script.Parent.TestPhase19)
	local TestPhase20 = require(script.Parent.TestPhase20)
	local TestPhase21 = require(script.Parent.TestPhase21)

	TestBootSmoke.run()
	TestPhase4_5.runGeometry()
	TestPhase5.runUnit()
	TestPhase6.runUnit()
	TestPhase9.runUnit()
	TestPhase11.runUnit()
	TestPhase13.runUnit()
	TestPhase14.runUnit()
	TestPhase14_5.runUnit()
	TestPhase19.run()
	TestPhase20.run()
	TestPhase21.runUnit()
end

function TestGates.runMechanicsRegression()
	local TestPhase4 = require(script.Parent.TestPhase4)
	local TestPhase15 = require(script.Parent.TestPhase15)
	local TestPhase16 = require(script.Parent.TestPhase16)
	local TestPhase18 = require(script.Parent.TestPhase18)
	local TestPhase21 = require(script.Parent.TestPhase21)

	TestPhase4.run()
	TestPhase15.run()
	TestPhase16.run()
	TestPhase18.run()
	TestPhase21.runIntegration()
	TestPhase21.runExperiment()
end

return TestGates
