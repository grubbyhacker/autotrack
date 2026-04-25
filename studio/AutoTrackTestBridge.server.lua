local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StudioTestService = game:GetService("StudioTestService")

local PLUGIN_NAME = "AutoTrackTestBridge"
local PLUGIN_VERSION = "phase38.1"
local WIDGET_ID = "AutoTrackTestBridgeStatus"
local SETTINGS_KEY_ENABLED = "bridge_enabled"
local DEFAULT_BASE_URL = "http://127.0.0.1:8765"
local DEFAULT_POLL_SECONDS = 1
local POLL_ERROR_LOG_INTERVAL_SECONDS = 10
local BRIDGE_EXPORT_REQUEST_ATTR = "AutoTrack_BridgeExportLLMTraceRequestId"
local BRIDGE_EXPORT_RESULT_ATTR = "AutoTrack_BridgeExportLLMTraceResultId"
local BRIDGE_EXPORT_ERROR_ATTR = "AutoTrack_BridgeExportLLMTraceError"
local TEST_STATUS_FOLDER_NAME = "AutoTrackTestStatus"
local TEST_STATUS_PAYLOAD_NAME = "PayloadJson"
local TEST_STATUS_PAYLOAD_CHUNKS_FOLDER_NAME = "PayloadChunks"

local toolbar = plugin:CreateToolbar("AutoTrack")
local toggleButton = toolbar:CreateButton(
	PLUGIN_NAME,
	"Open the AutoTrack localhost test bridge status panel",
	"rbxasset://textures/DeveloperFramework/checkbox_checked.png"
)

local enabled = plugin:GetSetting(SETTINGS_KEY_ENABLED)
if enabled == nil then
	enabled = true
end

local lastPollErrorLogAt = 0
local lastWarnPollErrorText = ""
local lastPollAtText = "never"
local lastPollResultText = "not polled"
local lastPollErrorText = ""
local currentCommand = nil
local statusRows = {}
local diagnosticsTextBox: TextBox? = nil
local bridgeToggleButton: TextButton? = nil

local widgetInfo = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 360, 420, 280, 300)
local widget = plugin:CreateDockWidgetPluginGui(WIDGET_ID, widgetInfo)
widget.Title = PLUGIN_NAME

local busy = false

local function syncButton()
	toggleButton:SetActive(enabled)
	if bridgeToggleButton ~= nil then
		bridgeToggleButton.Text = if enabled then "Bridge Enabled: ON" else "Bridge Enabled: OFF"
		bridgeToggleButton.BackgroundColor3 = if enabled
			then Color3.fromRGB(36, 116, 72)
			else Color3.fromRGB(120, 64, 64)
	end
end

local function warnPollFailure(err)
	local now = os.clock()
	local errText = tostring(err)
	if errText == "" then
		errText = "unknown poll failure"
	end
	local isConnectFail = string.find(errText, "ConnectFail", 1, true) ~= nil
	if isConnectFail then
		-- No local bridge process is expected most of the time while Studio is idle.
		-- Silence this case entirely; the CLI side is authoritative when a bridge
		-- command is actually expected to be live.
		return
	end

	if string.find(errText, "Http requests can only be executed by game server", 1, true) ~= nil then
		-- This plugin is only meant to poll from the Studio/edit or server-side Play
		-- contexts. Client-side Play polling is skipped below; suppress any race/noise.
		return
	end

	local sameAsLast = errText == lastWarnPollErrorText
	local withinInterval = (now - lastPollErrorLogAt) < POLL_ERROR_LOG_INTERVAL_SECONDS
	if sameAsLast and withinInterval then
		return
	end

	lastPollErrorLogAt = now
	lastWarnPollErrorText = errText

	local hint = "Ensure the plugin is enabled and localhost HTTP permissions are allowed in Studio."
	if isConnectFail then
		hint = "No local bridge process is listening. This is normal unless a make/test command is currently running."
	elseif string.find(string.lower(errText), "http", 1, true) then
		hint = "Local bridge may be down or blocked. Re-check Studio localhost HTTP permission prompts."
	end

	warn(string.format("[%s] bridge poll failed: %s | %s", PLUGIN_NAME, errText, hint))
end

local function getContextText(): string
	if RunService:IsRunning() then
		if RunService:IsClient() then
			return "play_client"
		end
		return "play_server"
	end

	return "edit"
end

local function shouldPollBridge(): boolean
	if RunService:IsRunning() and RunService:IsClient() then
		return false
	end

	return true
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

local function commandField(fieldName: string): string
	if type(currentCommand) ~= "table" then
		return ""
	end

	local value = currentCommand[fieldName]
	if value == nil then
		return ""
	end
	return tostring(value)
end

local function pollPath(): string
	local query = {
		"plugin_name=" .. HttpService:UrlEncode(PLUGIN_NAME),
		"version=" .. HttpService:UrlEncode(PLUGIN_VERSION),
		"enabled=" .. tostring(enabled),
		"busy=" .. tostring(busy),
		"context=" .. HttpService:UrlEncode(getContextText()),
	}

	local currentId = commandField("id")
	if currentId ~= "" then
		table.insert(query, "current_command_id=" .. HttpService:UrlEncode(currentId))
	end

	local currentSuite = commandField("suite")
	if currentSuite ~= "" then
		table.insert(query, "current_suite=" .. HttpService:UrlEncode(currentSuite))
	end

	return "/poll?" .. table.concat(query, "&")
end

local function diagnosticsText(): string
	local lines = {
		PLUGIN_NAME .. " diagnostics",
		"version=" .. PLUGIN_VERSION,
		"enabled=" .. tostring(enabled),
		"base_url=" .. DEFAULT_BASE_URL,
		"poll_seconds=" .. tostring(DEFAULT_POLL_SECONDS),
		"context=" .. getContextText(),
		"last_poll_at=" .. lastPollAtText,
		"last_poll_result=" .. lastPollResultText,
		"last_error=" .. lastPollErrorText,
		"busy=" .. tostring(busy),
		"current_command_id=" .. commandField("id"),
		"current_suite=" .. commandField("suite"),
	}

	return table.concat(lines, "\n")
end

local function setRow(name: string, value: string)
	local row = statusRows[name]
	if row ~= nil then
		row.Text = value
	end
end

local function refreshStatusPanel()
	setRow("enabled", tostring(enabled))
	setRow("url", DEFAULT_BASE_URL)
	setRow("lastPoll", lastPollAtText .. " | " .. lastPollResultText)
	setRow("lastError", if lastPollErrorText ~= "" then lastPollErrorText else "none")
	setRow("busy", tostring(busy))
	setRow("command", commandField("id"))
	setRow("suite", commandField("suite"))
	setRow("context", getContextText())
	if diagnosticsTextBox ~= nil then
		diagnosticsTextBox.Text = diagnosticsText()
	end
	syncButton()
end

local function setEnabled(nextEnabled: boolean)
	enabled = nextEnabled
	plugin:SetSetting(SETTINGS_KEY_ENABLED, enabled)
	refreshStatusPanel()
end

local function addCorner(parent: Instance, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

local function makeTextLabel(parent: Instance, text: string, size: UDim2, position: UDim2, color: Color3)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.SourceSans
	label.TextSize = 14
	label.TextColor3 = color
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextWrapped = true
	label.Text = text
	label.Size = size
	label.Position = position
	label.Parent = parent
	return label
end

local function createStatusRow(parent: Instance, rowIndex: number, labelText: string, rowKey: string)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 22)
	row.LayoutOrder = rowIndex
	row.Parent = parent

	makeTextLabel(row, labelText, UDim2.new(0, 118, 1, 0), UDim2.fromOffset(0, 0), Color3.fromRGB(190, 198, 210))
	local valueLabel =
		makeTextLabel(row, "", UDim2.new(1, -124, 1, 0), UDim2.fromOffset(124, 0), Color3.fromRGB(238, 242, 247))
	statusRows[rowKey] = valueLabel
end

local function createStatusPanel()
	local root = Instance.new("Frame")
	root.BackgroundColor3 = Color3.fromRGB(34, 37, 43)
	root.BorderSizePixel = 0
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = widget

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 12)
	padding.PaddingBottom = UDim.new(0, 12)
	padding.PaddingLeft = UDim.new(0, 12)
	padding.PaddingRight = UDim.new(0, 12)
	padding.Parent = root

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = root

	local title = makeTextLabel(
		root,
		"AutoTrack Bridge",
		UDim2.new(1, 0, 0, 24),
		UDim2.fromOffset(0, 0),
		Color3.fromRGB(255, 255, 255)
	)
	title.Font = Enum.Font.SourceSansBold
	title.TextSize = 18
	title.LayoutOrder = 1

	local toggle = Instance.new("TextButton")
	toggle.Font = Enum.Font.SourceSansBold
	toggle.TextSize = 14
	toggle.TextColor3 = Color3.fromRGB(255, 255, 255)
	toggle.BorderSizePixel = 0
	toggle.Size = UDim2.new(1, 0, 0, 32)
	toggle.LayoutOrder = 2
	toggle.Parent = root
	addCorner(toggle, 6)
	bridgeToggleButton = toggle
	toggle.MouseButton1Click:Connect(function()
		setEnabled(not enabled)
	end)

	local rows = Instance.new("Frame")
	rows.BackgroundTransparency = 1
	rows.Size = UDim2.new(1, 0, 0, 190)
	rows.LayoutOrder = 3
	rows.Parent = root

	local rowsLayout = Instance.new("UIListLayout")
	rowsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowsLayout.Padding = UDim.new(0, 2)
	rowsLayout.Parent = rows

	createStatusRow(rows, 1, "Enabled", "enabled")
	createStatusRow(rows, 2, "Poll URL", "url")
	createStatusRow(rows, 3, "Last poll", "lastPoll")
	createStatusRow(rows, 4, "Last error", "lastError")
	createStatusRow(rows, 5, "Busy", "busy")
	createStatusRow(rows, 6, "Command", "command")
	createStatusRow(rows, 7, "Suite", "suite")
	createStatusRow(rows, 8, "Context", "context")

	local copyButton = Instance.new("TextButton")
	copyButton.Font = Enum.Font.SourceSansBold
	copyButton.TextSize = 14
	copyButton.Text = "Copy Diagnostics"
	copyButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	copyButton.BackgroundColor3 = Color3.fromRGB(54, 91, 153)
	copyButton.BorderSizePixel = 0
	copyButton.Size = UDim2.new(1, 0, 0, 30)
	copyButton.LayoutOrder = 4
	copyButton.Parent = root
	addCorner(copyButton, 6)

	local diagnosticsBox = Instance.new("TextBox")
	diagnosticsBox.BackgroundColor3 = Color3.fromRGB(24, 26, 31)
	diagnosticsBox.BorderSizePixel = 0
	diagnosticsBox.ClearTextOnFocus = false
	diagnosticsBox.Font = Enum.Font.Code
	diagnosticsBox.MultiLine = true
	diagnosticsBox.PlaceholderText = ""
	diagnosticsBox.Size = UDim2.new(1, 0, 0, 88)
	diagnosticsBox.Text = diagnosticsText()
	diagnosticsBox.TextColor3 = Color3.fromRGB(232, 236, 244)
	diagnosticsBox.TextEditable = false
	diagnosticsBox.TextSize = 13
	diagnosticsBox.TextWrapped = false
	diagnosticsBox.TextXAlignment = Enum.TextXAlignment.Left
	diagnosticsBox.TextYAlignment = Enum.TextYAlignment.Top
	diagnosticsBox.LayoutOrder = 5
	diagnosticsBox.Parent = root
	addCorner(diagnosticsBox, 4)
	diagnosticsTextBox = diagnosticsBox

	copyButton.MouseButton1Click:Connect(function()
		diagnosticsBox.Text = diagnosticsText()
		pcall(function()
			diagnosticsBox:CaptureFocus()
			diagnosticsBox.CursorPosition = 1
			diagnosticsBox.SelectionStart = #diagnosticsBox.Text + 1
		end)
	end)

	refreshStatusPanel()
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

local function executeCommand(command)
	busy = true
	currentCommand = command
	refreshStatusPanel()
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
	currentCommand = nil
	refreshStatusPanel()
end

toggleButton.Click:Connect(function()
	widget.Enabled = true
	refreshStatusPanel()
end)

createStatusPanel()
syncButton()

task.spawn(function()
	print(
		string.format(
			"[%s] polling %s every %.1fs (enabled=%s)",
			PLUGIN_NAME,
			DEFAULT_BASE_URL,
			DEFAULT_POLL_SECONDS,
			tostring(enabled)
		)
	)
	while true do
		if shouldPollBridge() then
			local ok, response = pcall(function()
				return request("GET", pollPath(), nil)
			end)

			lastPollAtText = string.format("%.1fs", os.clock())
			if ok then
				lastPollResultText = if response.command ~= nil then "command received" else "idle"
				lastPollErrorText = ""
				lastWarnPollErrorText = ""
				if response.command ~= nil and enabled and not busy then
					task.spawn(executeCommand, response.command)
				end
			else
				lastPollResultText = "error"
				lastPollErrorText = tostring(response)
				warnPollFailure(response)
			end
		else
			lastPollResultText = "skipped"
			lastPollErrorText = "client Play context cannot execute plugin HTTP requests"
		end

		refreshStatusPanel()
		task.wait(DEFAULT_POLL_SECONDS)
	end
end)
