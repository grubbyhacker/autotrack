type TestSnapshot = {
	status: string,
	pass_count: number,
	fail_count: number,
	error_count: number,
	message: string?,
	lines: { string }?,
}

type RunSuiteHandler = (string) -> TestSnapshot

local TestSuiteRunner = {}

local runner: RunSuiteHandler? = nil

function TestSuiteRunner.setRunner(handler: RunSuiteHandler?)
	runner = handler
end

function TestSuiteRunner.getRunner(): RunSuiteHandler?
	return runner
end

function TestSuiteRunner.isConfigured(): boolean
	return runner ~= nil
end

function TestSuiteRunner.runSuite(suite: string): TestSnapshot?
	if runner == nil then
		return nil
	end
	return runner(suite)
end

return TestSuiteRunner
