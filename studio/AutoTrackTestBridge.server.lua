local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StudioTestService = game:GetService("StudioTestService")

local PLUGIN_NAME = "AutoTrackTestBridge"
local SETTINGS_KEY_ENABLED = "bridge_enabled"
local DEFAULT_BASE_URL = "http://127.0.0.1:8765"
local DEFAULT_POLL_SECONDS = 1
local BRIDGE_EXPORT_REQUEST_ATTR = "AutoTrack_BridgeExportLLMTraceRequestId"
local BRIDGE_EXPORT_RESULT_ATTR = "AutoTrack_BridgeExportLLMTraceResultId"
local BRIDGE_EXPORT_ERROR_ATTR = "AutoTrack_BridgeExportLLMTraceError"
local TEST_STATUS_FOLDER_NAME = "AutoTrackTestStatus"
local TEST_STATUS_PAYLOAD_NAME = "PayloadJson"
local TEST_STATUS_PAYLOAD_CHUNKS_FOLDER_NAME = "PayloadChunks"

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
		command_type = command.command_type,
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
	result.command_type = result.command_type or command.command_type
	result.lines = result.lines or {}
	result.pass_count = result.pass_count or 0
	result.fail_count = result.fail_count or 0
	result.error_count = result.error_count or 0
	result.status = result.status or "error"
	result.ok = result.status == "passed"
	return result
end

local function buildExportResult(command, exportPayload, summaryLine: string?)
	return {
		id = command.id,
		suite = command.suite,
		boot_mode = command.boot_mode,
		command_type = command.command_type,
		status = "passed",
		message = "",
		pass_count = 1,
		fail_count = 0,
		error_count = 0,
		lines = {
			summaryLine or "[TRACE EXPORT] live session export complete",
		},
		payload = {
			llm_trace_export = exportPayload,
		},
	}
end

local function decodeChunkedPayload(statusFolder: Folder, manifest)
	if type(manifest) ~= "table" or manifest.chunked ~= true then
		return nil, "invalid chunked payload manifest"
	end

	local chunkCount = tonumber(manifest.chunk_count)
	if type(chunkCount) ~= "number" or chunkCount < 1 then
		return nil, "chunked payload missing chunk_count"
	end

	local chunksFolder = statusFolder:FindFirstChild(TEST_STATUS_PAYLOAD_CHUNKS_FOLDER_NAME)
	if not chunksFolder or not chunksFolder:IsA("Folder") then
		return nil, "chunked payload folder missing"
	end

	local children = chunksFolder:GetChildren()
	table.sort(children, function(a, b)
		return a.Name < b.Name
	end)

	local parts = table.create(chunkCount)
	local found = 0
	for _, child in ipairs(children) do
		if child:IsA("StringValue") then
			found += 1
			if found <= chunkCount then
				parts[found] = child.Value
			end
		end
	end
	if found < chunkCount then
		return nil, string.format("chunked payload incomplete (%d/%d)", found, chunkCount)
	end

	local encoded = table.concat(parts, "")
	local totalLength = tonumber(manifest.total_length)
	if type(totalLength) == "number" and totalLength > 0 and #encoded ~= totalLength then
		return nil, string.format("chunked payload length mismatch (%d/%d)", #encoded, totalLength)
	end

	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(encoded)
	end)
	if not ok then
		return nil, "chunked payload invalid json"
	end
	return decoded, nil
end

local function readLiveExportPayload()
	local statusFolder = ReplicatedStorage:FindFirstChild(TEST_STATUS_FOLDER_NAME)
	if not statusFolder or not statusFolder:IsA("Folder") then
		return nil, "test status folder missing"
	end

	local payloadValue = statusFolder:FindFirstChild(TEST_STATUS_PAYLOAD_NAME)
	if not payloadValue or not payloadValue:IsA("StringValue") then
		return nil, "trace payload missing"
	end
	if payloadValue.Value == "" then
		return nil, "trace payload empty"
	end

	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(payloadValue.Value)
	end)
	if not ok then
		return nil, "trace payload invalid json"
	end

	if type(decoded) == "table" and decoded.chunked == true then
		local chunkedDecoded, chunkErr = decodeChunkedPayload(statusFolder, decoded)
		if chunkedDecoded == nil then
			return nil, chunkErr or "chunked payload decode failed"
		end
		decoded = chunkedDecoded
	end

	local exportPayload = decoded and decoded.llm_trace_export
	if type(exportPayload) ~= "table" then
		return nil, "llm_trace_export missing from payload"
	end

	return exportPayload, nil
end

local function runLiveLLMTraceExport(command)
	if not RunService:IsRunning() then
		return buildFallbackResult(command, "no active Play session for LLM trace export")
	end

	workspace:SetAttribute(BRIDGE_EXPORT_ERROR_ATTR, "")
	workspace:SetAttribute(BRIDGE_EXPORT_REQUEST_ATTR, command.id)

	local timeoutSeconds = tonumber(command.suite_seconds) or 30
	local deadline = os.clock() + timeoutSeconds
	while os.clock() < deadline do
		if workspace:GetAttribute(BRIDGE_EXPORT_RESULT_ATTR) == command.id then
			local errText = workspace:GetAttribute(BRIDGE_EXPORT_ERROR_ATTR)
			if type(errText) == "string" and errText ~= "" then
				return buildFallbackResult(command, errText)
			end

			local exportPayload, payloadErr = readLiveExportPayload()
			if exportPayload == nil then
				return buildFallbackResult(command, payloadErr or "llm trace export missing payload")
			end

			return buildExportResult(
				command,
				exportPayload,
				string.format(
					"[TRACE EXPORT] run=%s events=%d live_session=true",
					tostring(exportPayload.run_id),
					tonumber(exportPayload.event_count) or 0
				)
			)
		end

		task.wait(0.2)
	end

	return buildFallbackResult(command, "timed out waiting for active-session LLM trace export")
end

local function isLiveTraceExportCommand(command): boolean
	return command.command_type == "export_llm_trace"
		or command.suite == "llm_trace_export"
		or command.boot_mode == "live_session"
end

local busy = false

local function executeCommand(command)
	busy = true
	local ok, result
	if isLiveTraceExportCommand(command) then
		ok, result = pcall(function()
			return runLiveLLMTraceExport(command)
		end)
	else
		local priorSkipBootBaseline = workspace:GetAttribute("AutoTrack_SkipBootBaseline")
		local priorLLMEnabled = workspace:GetAttribute("AutoTrack_LLMEnabled")
		local priorLLMModel = workspace:GetAttribute("AutoTrack_LLMModel")
		ok, result = pcall(function()
			workspace:SetAttribute("AutoTrack_SkipBootBaseline", command.boot_mode == "skip_baseline")
			if command.command_type == "endurance_trace" then
				workspace:SetAttribute("AutoTrack_LLMEnabled", command.llm_enabled == true)
				if type(command.llm_model) == "string" and command.llm_model ~= "" then
					workspace:SetAttribute("AutoTrack_LLMModel", command.llm_model)
				end
			end
			return StudioTestService:ExecutePlayModeAsync(command)
		end)
		workspace:SetAttribute("AutoTrack_SkipBootBaseline", priorSkipBootBaseline)
		workspace:SetAttribute("AutoTrack_LLMEnabled", priorLLMEnabled)
		workspace:SetAttribute("AutoTrack_LLMModel", priorLLMModel)
	end

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
