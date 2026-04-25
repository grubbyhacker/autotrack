--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))

type SectorMeta = Types.SectorMeta

type RuntimeData = {
	sectors: { SectorMeta },
	car: BasePart,
	canonicalStart: CFrame,
	baselineLapTime: number,
}

type RuntimeContextModule = {
	init: (data: RuntimeData) -> (),
	isReady: () -> boolean,
	getSectors: () -> { SectorMeta },
	getSectorById: (id: number) -> SectorMeta,
	getCar: () -> BasePart,
	setCar: (car: BasePart) -> (),
	getCanonicalStart: () -> CFrame,
	getBaselineLapTime: () -> number,
	setBaselineLapTime: (seconds: number) -> (),
}

local RuntimeContext: RuntimeContextModule = {} :: RuntimeContextModule

local _state: {
	sectors: { SectorMeta }?,
	car: BasePart?,
	canonicalStart: CFrame?,
	baselineLapTime: number?,
} = {
	sectors = nil,
	car = nil,
	canonicalStart = nil,
	baselineLapTime = nil,
}

function RuntimeContext.init(data: RuntimeData): ()
	assert(data, "RuntimeContext.init: data is required")
	assert(data.sectors, "RuntimeContext.init: sectors missing")
	assert(data.car, "RuntimeContext.init: car missing")
	assert(data.canonicalStart, "RuntimeContext.init: canonicalStart missing")
	assert(data.baselineLapTime, "RuntimeContext.init: baselineLapTime missing")

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

function RuntimeContext.getSectors(): { SectorMeta }
	assert(RuntimeContext.isReady(), "RuntimeContext.getSectors: runtime context not ready")
	local sectors = _state.sectors
	assert(sectors ~= nil, "RuntimeContext.getSectors: sectors missing")
	return sectors
end

function RuntimeContext.getSectorById(id: number): SectorMeta
	assert(RuntimeContext.isReady(), "RuntimeContext.getSectorById: runtime context not ready")
	local sectors = _state.sectors
	assert(sectors ~= nil, "RuntimeContext.getSectorById: sectors missing")
	for _, sector in ipairs(sectors) do
		if sector.id == id then
			return sector
		end
	end
	error("RuntimeContext.getSectorById: unknown sector " .. tostring(id))
end

function RuntimeContext.getCar(): BasePart
	assert(RuntimeContext.isReady(), "RuntimeContext.getCar: runtime context not ready")
	local car = _state.car
	assert(car ~= nil, "RuntimeContext.getCar: car missing")
	return car
end

function RuntimeContext.setCar(car: BasePart): ()
	assert(car, "RuntimeContext.setCar: car missing")
	_state.car = car
end

function RuntimeContext.getCanonicalStart(): CFrame
	assert(RuntimeContext.isReady(), "RuntimeContext.getCanonicalStart: runtime context not ready")
	local canonicalStart = _state.canonicalStart
	assert(canonicalStart ~= nil, "RuntimeContext.getCanonicalStart: canonicalStart missing")
	return canonicalStart
end

function RuntimeContext.getBaselineLapTime(): number
	assert(RuntimeContext.isReady(), "RuntimeContext.getBaselineLapTime: runtime context not ready")
	local baselineLapTime = _state.baselineLapTime
	assert(baselineLapTime ~= nil, "RuntimeContext.getBaselineLapTime: baselineLapTime missing")
	return baselineLapTime
end

function RuntimeContext.setBaselineLapTime(seconds: number): ()
	assert(seconds ~= nil, "RuntimeContext.setBaselineLapTime: seconds missing")
	_state.baselineLapTime = seconds
end

return RuntimeContext
