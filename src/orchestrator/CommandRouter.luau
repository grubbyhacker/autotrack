local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local CameraDemo = require(script.Parent.CameraDemo)
local HotfixAgent = require(script.Parent.HotfixAgent)
local HUDPreviewDemo = require(script.Parent.HUDPreviewDemo)
local JobLock = require(script.Parent.JobLock)
local OrchestratorAgent = require(script.Parent.OrchestratorAgent)
local TestDispatcher = require(script.Parent.TestDispatcher)
local TuneMode = require(script.Parent.TuneMode)
local UIState = require(script.Parent.UIState)

local CommandRouter = {}

local SUPPORTED_DEMO_USAGE =
	"/demo endurance, /demo camera, /demo rampitup, /demo repair, /demo llmerror, /demo ui-hotfix"
local SUPPORTED_TUNE_USAGE =
	"usage: /tune <rampjump|crestdip|chicane> | /tune show | /tune run <n> | /tune compare <n> | /tune auto <on|off> | /tune set <lever> <value> | /tune pad <ingress|egress> <PadValue> | /tune attr <name> <value> | /tune reset | /tune revert | /tune commit | /tune promote | /tune stop"
local REMOVED_LLM_REASON = "LLM slash commands removed; use the HUD model selector or startup config"
local UNKNOWN_COMMAND_REASON = "unknown command; supported: /demo, /test, /tune"

local function trim(text: string): string
	return string.match(text, "^%s*(.-)%s*$") or ""
end

local function parseSlashCommand(text: string): (string?, string?)
	local command, rest = string.match(text, "^/([%a_]+)%s*(.-)%s*$")
	if not command then
		return nil, nil
	end
	return command, rest
end

local function parseTuneCommand(arg: string): (string, string)
	local head, tail = string.match(arg, "^(%S+)%s*(.-)%s*$")
	return head or "", tail or ""
end

local function activeDemoReason(targetCommand: string?): string
	local preset = CameraDemo.activePreset()
	if targetCommand and targetCommand ~= "" then
		return string.format("demo '%s' is running; stop it before %s", preset, targetCommand)
	end
	return string.format("demo '%s' is running; use /demo %s to toggle it off", preset, preset)
end

local function activeTuneReason(targetCommand: string?): string
	if targetCommand and targetCommand ~= "" then
		return string.format("tune mode is running; stop it before %s", targetCommand)
	end
	return "tune mode is running; use /tune stop to exit it"
end

local function activeEnduranceReason(): string
	return "endurance mode owns the session; restart or wait for it to finish"
end

local function activeLiveModeReason(): string?
	if OrchestratorAgent.isActive() then
		return activeEnduranceReason()
	end
	if HotfixAgent.isActive() or JobLock.isHeld() then
		return "track is busy; try again shortly"
	end
	return nil
end

local function reject(rawText: string, reason: string, warningText: string?): (boolean, string?)
	UIState.rejectRequest(rawText, reason, warningText)
	return false, reason
end

local function canonicalTuneMechanic(text: string): string?
	local normalized = trim(string.lower(text))
	if normalized == "rampjump" then
		return "RampJump"
	elseif normalized == "crestdip" then
		return "CrestDip"
	elseif normalized == "chicane" then
		return "Chicane"
	end
	return LevelMappings.MECHANIC_SYNONYMS[normalized]
end

local function handleTune(rawText: string, normalizedArg: string, rawArg: string): (boolean, string?)
	local tuneCommand, tuneRest = parseTuneCommand(rawArg)
	local canonicalMechanic = canonicalTuneMechanic(normalizedArg)

	if
		canonicalMechanic ~= nil
		and tuneCommand ~= "set"
		and tuneCommand ~= "pad"
		and tuneCommand ~= "attr"
		and tuneCommand ~= "run"
		and tuneCommand ~= "compare"
		and tuneCommand ~= "auto"
	then
		if CameraDemo.isActive() then
			return reject(rawText, activeDemoReason("/tune"), nil)
		end
		local liveModeReason = activeLiveModeReason()
		if liveModeReason ~= nil then
			return reject(rawText, liveModeReason, nil)
		end
		local ok, reason = TuneMode.start(canonicalMechanic)
		if not ok then
			return reject(rawText, tostring(reason), nil)
		end
		return true, nil
	end

	if tuneCommand == "show" then
		local ok, reason = TuneMode.show()
		if not ok then
			return reject(rawText, tostring(reason), nil)
		end
		return true, nil
	elseif tuneCommand == "set" then
		local lever, valueText = string.match(tuneRest, "^(%S+)%s*(.-)%s*$")
		local value = tonumber(valueText)
		if lever == nil or value == nil then
			return reject(rawText, "usage: /tune set <lever> <value>", nil)
		end
		local ok, reason = TuneMode.setLever(lever, value)
		if not ok then
			return reject(rawText, tostring(reason), nil)
		end
		return true, nil
	elseif tuneCommand == "pad" then
		local side, value = string.match(tuneRest, "^(%S+)%s*(%S+)%s*$")
		if side == nil or value == nil then
			return reject(rawText, "usage: /tune pad <ingress|egress> <PadValue>", nil)
		end
		local ok, reason = TuneMode.setPad(side, value)
		if not ok then
			return reject(rawText, tostring(reason), nil)
		end
		return true, nil
	elseif tuneCommand == "attr" then
		local name, valueText = string.match(tuneRest, "^(%S+)%s*(.-)%s*$")
		local value = tonumber(valueText)
		if name == nil or value == nil then
			return reject(rawText, "usage: /tune attr <name> <value>", nil)
		end
		local ok, reason = TuneMode.setAttr(name, value)
		if not ok then
			return reject(rawText, tostring(reason), nil)
		end
		return true, nil
	elseif tuneCommand == "run" then
		local attempts = tonumber(trim(tuneRest))
		if attempts == nil then
			return reject(rawText, "usage: /tune run <n>", nil)
		end
		local ok, reason = TuneMode.runAttempts(attempts)
		if not ok then
			return reject(rawText, tostring(reason), nil)
		end
		return true, nil
	elseif tuneCommand == "compare" then
		local attempts = tonumber(trim(tuneRest))
		if attempts == nil then
			return reject(rawText, "usage: /tune compare <n>", nil)
		end
		local ok, reason = TuneMode.compareBaseline(attempts)
		if not ok then
			return reject(rawText, tostring(reason), nil)
		end
		return true, nil
	elseif tuneCommand == "auto" then
		local mode = trim(string.lower(tuneRest))
		if mode ~= "on" and mode ~= "off" then
			return reject(rawText, "usage: /tune auto <on|off>", nil)
		end
		local ok, reason = TuneMode.setAuto(mode == "on")
		if not ok then
			return reject(rawText, tostring(reason), nil)
		end
		return true, nil
	elseif tuneCommand == "reset" then
		local ok, reason = TuneMode.reset()
		if not ok then
			return reject(rawText, tostring(reason), nil)
		end
		return true, nil
	elseif tuneCommand == "revert" then
		local ok, reason = TuneMode.revert()
		if not ok then
			return reject(rawText, tostring(reason), nil)
		end
		return true, nil
	elseif tuneCommand == "commit" then
		local ok, reason = TuneMode.commit()
		if not ok then
			return reject(rawText, tostring(reason), nil)
		end
		return true, nil
	elseif tuneCommand == "promote" then
		local ok, reason = TuneMode.promote()
		if not ok then
			return reject(rawText, tostring(reason), nil)
		end
		return true, nil
	elseif tuneCommand == "stop" then
		local ok, reason = TuneMode.stop()
		if not ok then
			return reject(rawText, tostring(reason), nil)
		end
		return true, nil
	end

	local supportedAttrs = table.concat(TuneMode.supportedAttrs(), ", ")
	return reject(rawText, SUPPORTED_TUNE_USAGE, "Supported tune attrs: " .. supportedAttrs)
end

local function handleDemo(rawText: string, normalizedArg: string, deps): (boolean, string?)
	if normalizedArg == "repair" or normalizedArg == "llmerror" or normalizedArg == "ui-hotfix" then
		if CameraDemo.isActive() then
			return reject(rawText, activeDemoReason("/demo " .. normalizedArg), nil)
		end
		local liveModeReason = activeLiveModeReason()
		if liveModeReason ~= nil then
			return reject(rawText, liveModeReason, nil)
		end
		local ok, reason = HUDPreviewDemo.toggle(normalizedArg)
		if not ok then
			return reject(rawText, tostring(reason), nil)
		end
		return true, nil
	end

	if normalizedArg == "camera" or normalizedArg == "rampitup" then
		if CameraDemo.isActive() then
			if CameraDemo.activePreset() == normalizedArg then
				return CameraDemo.stop()
			end
			return reject(rawText, activeDemoReason("/demo " .. normalizedArg), nil)
		end
		local liveModeReason = activeLiveModeReason()
		if liveModeReason ~= nil then
			return reject(rawText, liveModeReason, nil)
		end
		return CameraDemo.start({ preset = normalizedArg })
	end

	if normalizedArg == "endurance" then
		local startEndurance = if deps then deps.startEndurance else nil
		if type(startEndurance) ~= "function" then
			return reject(rawText, "endurance start unavailable", nil)
		end
		local ok, reason = startEndurance()
		if not ok then
			return reject(rawText, tostring(reason), nil)
		end
		return true, nil
	end

	if
		normalizedArg == "crest"
		or normalizedArg == "maximize"
		or normalizedArg == "extreme"
		or normalizedArg == "hotfix"
	then
		return reject(
			rawText,
			string.format("demo '%s' is not supported; supported: %s", normalizedArg, SUPPORTED_DEMO_USAGE),
			nil
		)
	end

	return reject(rawText, "unknown demo; supported: " .. SUPPORTED_DEMO_USAGE, nil)
end

local function handleTest(rawText: string, rawArg: string): (boolean, string?)
	local suite = trim(rawArg)
	if suite == "" then
		return reject(rawText, "test name missing; use /test <suite>", nil)
	end
	if CameraDemo.isActive() then
		return reject(rawText, activeDemoReason("/test"), nil)
	end
	local liveModeReason = activeLiveModeReason()
	if liveModeReason ~= nil then
		return reject(rawText, liveModeReason, nil)
	end

	UIState.setBusy(true)
	UIState.setPhase("RunTest", "Running server-side test...")
	UIState.appendLog("Running /test " .. suite)

	local snapshot = TestDispatcher.runSuite(suite)
	UIState.setBusy(false)

	if snapshot.status == "passed" then
		UIState.setPhase("RunTest", "Test passed")
		UIState.appendLog(string.format("Suite %s passed (%d pass)", suite, snapshot.pass_count))
		return true, nil
	end

	UIState.setPhase("RunTest", "Test failed")
	UIState.setError("test failed: " .. suite)
	UIState.appendLog(
		string.format(
			"Suite %s %s (%d fail, %d error)",
			suite,
			tostring(snapshot.status),
			snapshot.fail_count,
			snapshot.error_count
		)
	)
	return false, "test failed: " .. suite
end

function CommandRouter.route(rawText: string, deps): (boolean, boolean, string?)
	local trimmed = trim(rawText)
	local normalized = string.lower(trimmed)
	local slashCommand, slashArg = parseSlashCommand(normalized)
	if slashCommand == nil then
		return false, false, nil
	end

	local _, rawSlashArg = parseSlashCommand(trimmed)

	if slashCommand == "tune" then
		local ok, reason = handleTune(rawText, slashArg or "", rawSlashArg or "")
		return true, ok, reason
	end

	if TuneMode.isActive() then
		local ok, reason = reject(rawText, activeTuneReason("/" .. slashCommand), nil)
		return true, ok, reason
	end

	if slashCommand == "demo" then
		local ok, reason = handleDemo(rawText, slashArg or "", deps)
		return true, ok, reason
	end

	if slashCommand == "test" then
		local ok, reason = handleTest(rawText, rawSlashArg or "")
		return true, ok, reason
	end

	if slashCommand == "llm" then
		local ok, reason = reject(rawText, REMOVED_LLM_REASON, nil)
		return true, ok, reason
	end

	local ok, reason = reject(rawText, UNKNOWN_COMMAND_REASON, nil)
	return true, ok, reason
end

return CommandRouter
