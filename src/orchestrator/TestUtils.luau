--!strict

-- TestUtils.luau
-- Minimal pass/fail helpers for all phase test suites.

local TestSession = require(script.Parent.TestSession)

local T = {}

function T.pass(name: string)
	local line = "[TEST PASS: " .. name .. "]"
	print(line)
	TestSession.appendLine(line)
end

function T.fail(name: string, reason: string?)
	local line = "[TEST FAIL: " .. name .. "] " .. (reason or "assertion false")
	print(line)
	TestSession.appendLine(line)
end

function T.expect(name: string, cond: boolean, reason: string?)
	if cond then
		T.pass(name)
	else
		T.fail(name, reason)
	end
end

return T
