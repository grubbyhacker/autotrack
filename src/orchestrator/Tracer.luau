--!strict

-- In-memory trace log: prints and accumulates lines for test inspection.
local _log: { string } = {}

local Tracer = {}

function Tracer.log(line: string)
	print("[TRACE] " .. line)
	table.insert(_log, line)
end

function Tracer.getLog(): { string }
	return _log
end

function Tracer.clear()
	_log = {}
end

return Tracer
