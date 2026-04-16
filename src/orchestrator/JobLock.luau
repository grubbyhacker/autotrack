local JobLock = {}

local _held = false

function JobLock.tryAcquire(): boolean
	if _held then
		return false
	end

	_held = true
	return true
end

function JobLock.release()
	_held = false
end

function JobLock.isHeld(): boolean
	return _held
end

return JobLock
