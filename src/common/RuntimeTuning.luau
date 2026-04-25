--!strict

local RuntimeTuning = {}

function RuntimeTuning.numberAttr(name: string, fallback: number): number
	local value = workspace:GetAttribute(name)
	if type(value) == "number" then
		return value
	end
	return fallback
end

function RuntimeTuning.stringAttr(name: string, fallback: string): string
	local value = workspace:GetAttribute(name)
	if type(value) == "string" and value ~= "" then
		return value
	end
	return fallback
end

return RuntimeTuning
