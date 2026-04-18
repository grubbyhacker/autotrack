local PadValueUtils = {}

local VALUES = {
	None = { kind = "None", amount = 0 },
	Boost5 = { kind = "Boost", amount = 5 },
	Boost10 = { kind = "Boost", amount = 10 },
	Boost25 = { kind = "Boost", amount = 25 },
	Brake5 = { kind = "Brake", amount = 5 },
	Brake10 = { kind = "Brake", amount = 10 },
	Brake25 = { kind = "Brake", amount = 25 },
	-- Legacy aliases retained so old tests / provider responses still decode.
	Boost = { kind = "Boost", amount = 10 },
	Brake = { kind = "Brake", amount = 10 },
}

local BOOST_STEPS = { "Boost5", "Boost10", "Boost25" }
local BRAKE_STEPS = { "Brake5", "Brake10", "Brake25" }

function PadValueUtils.isValid(value: string): boolean
	return VALUES[value] ~= nil
end

function PadValueUtils.normalize(value: string): string
	if value == "Boost" then
		return "Boost10"
	end
	if value == "Brake" then
		return "Brake10"
	end
	return value
end

function PadValueUtils.kind(value: string): string
	local info = VALUES[PadValueUtils.normalize(value)]
	return if info then info.kind else "None"
end

function PadValueUtils.amount(value: string): number
	local info = VALUES[PadValueUtils.normalize(value)]
	return if info then info.amount else 0
end

function PadValueUtils.speedDelta(value: string): number
	local normalized = PadValueUtils.normalize(value)
	local kind = PadValueUtils.kind(normalized)
	local amount = PadValueUtils.amount(normalized)
	if kind == "Boost" then
		return amount
	elseif kind == "Brake" then
		return -amount
	end
	return 0
end

function PadValueUtils.display(value: string): string
	local normalized = PadValueUtils.normalize(value)
	local kind = PadValueUtils.kind(normalized)
	local amount = PadValueUtils.amount(normalized)
	if kind == "None" then
		return "REMOVE PAD"
	end
	local sign = if kind == "Boost" then "+" else "-"
	return string.format("%s %s%d", string.upper(kind), sign, amount)
end

function PadValueUtils.default(kind: string): string
	if kind == "Boost" then
		return "Boost10"
	elseif kind == "Brake" then
		return "Brake10"
	end
	return "None"
end

function PadValueUtils.fromKindAmount(kind: string, amount: number?): string
	if kind == "None" then
		return "None"
	end

	local absAmount = math.abs(amount or 10)
	if kind == "Boost" then
		if absAmount <= 5 then
			return "Boost5"
		elseif absAmount >= 25 then
			return "Boost25"
		end
		return "Boost10"
	elseif kind == "Brake" then
		if absAmount <= 5 then
			return "Brake5"
		elseif absAmount >= 25 then
			return "Brake25"
		end
		return "Brake10"
	end

	return "None"
end

local function nextStep(list, current: string): string?
	for index, value in ipairs(list) do
		if value == current then
			return list[math.min(index + 1, #list)]
		end
	end
	return list[1]
end

local function previousStep(list, current: string): string?
	for index, value in ipairs(list) do
		if value == current then
			if index <= 1 then
				return "None"
			end
			return list[index - 1]
		end
	end
	return "None"
end

function PadValueUtils.stronger(kind: string, current: string): string
	local normalized = PadValueUtils.normalize(current)
	if kind == "Boost" then
		if PadValueUtils.kind(normalized) ~= "Boost" then
			return "Boost10"
		end
		return nextStep(BOOST_STEPS, normalized) or "Boost25"
	elseif kind == "Brake" then
		if PadValueUtils.kind(normalized) ~= "Brake" then
			return "Brake10"
		end
		return nextStep(BRAKE_STEPS, normalized) or "Brake25"
	end
	return "None"
end

function PadValueUtils.weaker(kind: string, current: string): string
	local normalized = PadValueUtils.normalize(current)
	if kind == "Boost" then
		if PadValueUtils.kind(normalized) ~= "Boost" then
			return "None"
		end
		return previousStep(BOOST_STEPS, normalized) or "None"
	elseif kind == "Brake" then
		if PadValueUtils.kind(normalized) ~= "Brake" then
			return "None"
		end
		return previousStep(BRAKE_STEPS, normalized) or "None"
	end
	return "None"
end

function PadValueUtils.allowedValues(): { string }
	return { "None", "Boost5", "Boost10", "Boost25", "Brake5", "Brake10", "Brake25" }
end

return PadValueUtils
