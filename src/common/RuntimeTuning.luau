local RuntimeTuning = {}

function RuntimeTuning.numberAttr(name: string, fallback: number): number
	local value = workspace:GetAttribute(name)
	if type(value) == "number" then
		return value
	end
	return fallback
end

return RuntimeTuning
