local RuntimeContext = {}

local _state = {
	sectors = nil,
	car = nil,
	canonicalStart = nil,
	baselineLapTime = nil,
}

function RuntimeContext.init(data)
	assert(data, "RuntimeContext.init: data is required")
	assert(data.sectors ~= nil, "RuntimeContext.init: sectors missing")
	assert(data.car ~= nil, "RuntimeContext.init: car missing")
	assert(data.canonicalStart ~= nil, "RuntimeContext.init: canonicalStart missing")
	assert(data.baselineLapTime ~= nil, "RuntimeContext.init: baselineLapTime missing")

	_state.sectors = data.sectors
	_state.car = data.car
	_state.canonicalStart = data.canonicalStart
	_state.baselineLapTime = data.baselineLapTime
end

function RuntimeContext.isReady(): boolean
	return _state.sectors ~= nil
		and _state.car ~= nil
		and _state.canonicalStart ~= nil
		and _state.baselineLapTime ~= nil
end

function RuntimeContext.getSectors()
	assert(RuntimeContext.isReady(), "RuntimeContext.getSectors: runtime context not ready")
	return _state.sectors
end

function RuntimeContext.getSectorById(id: number)
	assert(RuntimeContext.isReady(), "RuntimeContext.getSectorById: runtime context not ready")
	for _, sector in ipairs(_state.sectors) do
		if sector.id == id then
			return sector
		end
	end
	error("RuntimeContext.getSectorById: unknown sector " .. tostring(id))
end

function RuntimeContext.getCar()
	assert(RuntimeContext.isReady(), "RuntimeContext.getCar: runtime context not ready")
	return _state.car
end

function RuntimeContext.getCanonicalStart(): CFrame
	assert(RuntimeContext.isReady(), "RuntimeContext.getCanonicalStart: runtime context not ready")
	return _state.canonicalStart
end

function RuntimeContext.getBaselineLapTime(): number
	assert(RuntimeContext.isReady(), "RuntimeContext.getBaselineLapTime: runtime context not ready")
	return _state.baselineLapTime
end

return RuntimeContext
