local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")

local PLUGIN_NAME = "AutoTrackTestBridge"
local SETTINGS_KEY_ENABLED = "bridge_enabled"
local DEFAULT_BASE_URL = "http://127.0.0.1:8765"
local DEFAULT_POLL_SECONDS = 1

local toolbar = plugin:CreateToolbar("AutoTrack")
local toggleButton = toolbar:CreateButton(
	PLUGIN_NAME,
	"Toggle the AutoTrack localhost test bridge",
	"rbxasset://textures/DeveloperFramework/checkbox_checked.png"
)

local enabled = plugin:GetSetting(SETTINGS_KEY_ENABLED)
if enabled == nil then
	enabled = true
end

local function syncButton()
	toggleButton:SetActive(enabled)
end

local function request(method: string, path: string, body)
	local url = DEFAULT_BASE_URL .. path
	local payload = {
		Url = url,
		Method = method,
		Headers = {
			["Content-Type"] = "application/json",
		},
	}

	if body ~= nil then
		payload.Body = HttpService:JSONEncode(body)
	end

	local response = HttpService:RequestAsync(payload)
	if not response.Success then
		error(string.format("HTTP %s %s failed: %s", method, url, tostring(response.StatusMessage)))
	end

	if response.Body == "" then
		return {}
	end

	return HttpService:JSONDecode(response.Body)
end

local function buildFallbackResult(command, errText: string)
	return {
		id = command.id,
		suite = command.suite,
		boot_mode = command.boot_mode,
		status = "error",
		message = errText,
		pass_count = 0,
		fail_count = 0,
		error_count = 1,
		lines = {
			"[TEST ERROR] " .. errText,
		},
	}
end

local function normaliseResult(command, ok: boolean, result)
	if not ok then
		return buildFallbackResult(command, tostring(result))
	end

	if type(result) ~= "table" then
		return buildFallbackResult(command, "Studio test returned a non-table result")
	end

	result.id = command.id
	result.suite = result.suite or command.suite
	result.boot_mode = result.boot_mode or command.boot_mode
	result.lines = result.lines or {}
	result.pass_count = result.pass_count or 0
	result.fail_count = result.fail_count or 0
	result.error_count = result.error_count or 0
	result.status = result.status or "error"
	result.ok = result.status == "passed"
	return result
end

local busy = false

local function executeCommand(command)
	busy = true
	local priorSkipBootBaseline = workspace:GetAttribute("AutoTrack_SkipBootBaseline")

	local ok, result = pcall(function()
		workspace:SetAttribute("AutoTrack_SkipBootBaseline", command.boot_mode == "skip_baseline")
		return StudioTestService:ExecutePlayModeAsync(command)
	end)

	workspace:SetAttribute("AutoTrack_SkipBootBaseline", priorSkipBootBaseline)

	local payload = normaliseResult(command, ok, result)
	local postOk, postErr = pcall(function()
		request("POST", "/result", payload)
	end)

	if not postOk then
		warn(string.format("[%s] failed to post result: %s", PLUGIN_NAME, tostring(postErr)))
	end

	busy = false
end

toggleButton.Click:Connect(function()
	enabled = not enabled
	plugin:SetSetting(SETTINGS_KEY_ENABLED, enabled)
	syncButton()
end)

syncButton()

task.spawn(function()
	while true do
		if enabled and not busy then
			local ok, response = pcall(function()
				return request("GET", "/poll?plugin_name=" .. PLUGIN_NAME, nil)
			end)

			if ok and response.command ~= nil then
				task.spawn(executeCommand, response.command)
			elseif not ok then
				-- Local bridge is expected to be absent most of the time.
			end
		end

		task.wait(DEFAULT_POLL_SECONDS)
	end
end)
