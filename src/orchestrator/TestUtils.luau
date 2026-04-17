-- TestUtils.luau
-- Minimal pass/fail helpers for all phase test suites.

local T = {}

function T.pass(name: string)
	print("[TEST PASS: " .. name .. "]")
end

function T.fail(name: string, reason: string?)
	print("[TEST FAIL: " .. name .. "] " .. (reason or "assertion false"))
end

function T.expect(name: string, cond: boolean, reason: string?)
	if cond then T.pass(name) else T.fail(name, reason) end
end

return T
