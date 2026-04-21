local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local STATUS_FOLDER_NAME = "AutoTrackTestStatus"
local LINES_FOLDER_NAME = "Lines"
local PAYLOAD_VALUE_NAME = "PayloadJson"

local TestSession = {}
local _payload = nil

local function ensureFolder(name: string, parent: Instance): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function getStatusFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild(STATUS_FOLDER_NAME)
	if folder and folder:IsA("Folder") then
		return folder
	end

	local created = Instance.new("Folder")
	created.Name = STATUS_FOLDER_NAME
	created.Parent = ReplicatedStorage
	return created
end

local function getLinesFolder(): Folder
	return ensureFolder(LINES_FOLDER_NAME, getStatusFolder())
end

local function getPayloadValue(): StringValue
	local folder = getStatusFolder()
	local existing = folder:FindFirstChild(PAYLOAD_VALUE_NAME)
	if existing and existing:IsA("StringValue") then
		return existing
	end

	local created = Instance.new("StringValue")
	created.Name = PAYLOAD_VALUE_NAME
	created.Value = ""
	created.Parent = folder
	return created
end

local function clearLines()
	local linesFolder = getLinesFolder()
	for _, child in ipairs(linesFolder:GetChildren()) do
		child:Destroy()
	end
end

local function appendLineValue(line: string)
	local linesFolder = getLinesFolder()
	local value = Instance.new("StringValue")
	value.Name = string.format("%04d", #linesFolder:GetChildren() + 1)
	value.Value = line
	value.Parent = linesFolder
end

function TestSession.beginSuite(suiteName: string)
	local folder = getStatusFolder()
	clearLines()
	_payload = nil
	getPayloadValue().Value = ""

	folder:SetAttribute("suite", suiteName)
	folder:SetAttribute("started", true)
	folder:SetAttribute("done", false)
	folder:SetAttribute("status", "running")
	folder:SetAttribute("message", "")
	folder:SetAttribute("pass_count", 0)
	folder:SetAttribute("fail_count", 0)
	folder:SetAttribute("error_count", 0)
	folder:SetAttribute("started_at", DateTime.now().UnixTimestampMillis)
	folder:SetAttribute("finished_at", 0)
end

function TestSession.appendLine(line: string)
	local folder = getStatusFolder()
	appendLineValue(line)

	if string.find(line, "[TEST PASS:", 1, true) ~= nil then
		folder:SetAttribute("pass_count", (folder:GetAttribute("pass_count") or 0) + 1)
	elseif string.find(line, "[TEST FAIL:", 1, true) ~= nil then
		folder:SetAttribute("fail_count", (folder:GetAttribute("fail_count") or 0) + 1)
	elseif string.find(line, "[TEST ERROR]", 1, true) ~= nil then
		folder:SetAttribute("error_count", (folder:GetAttribute("error_count") or 0) + 1)
	end
end

function TestSession.finishSuite(status: string, message: string?)
	local folder = getStatusFolder()
	folder:SetAttribute("done", true)
	folder:SetAttribute("status", status)
	folder:SetAttribute("message", message or "")
	folder:SetAttribute("finished_at", DateTime.now().UnixTimestampMillis)
end

function TestSession.setPayload(payload)
	_payload = payload
	local encoded = ""
	if payload ~= nil then
		encoded = HttpService:JSONEncode(payload)
	end
	getPayloadValue().Value = encoded
end

function TestSession.snapshot()
	local folder = getStatusFolder()
	local lines = {}
	local children = getLinesFolder():GetChildren()
	table.sort(children, function(a, b)
		return a.Name < b.Name
	end)
	for _, child in ipairs(children) do
		if child:IsA("StringValue") then
			table.insert(lines, child.Value)
		end
	end

	return {
		suite = folder:GetAttribute("suite"),
		started = folder:GetAttribute("started") == true,
		done = folder:GetAttribute("done") == true,
		status = folder:GetAttribute("status"),
		message = folder:GetAttribute("message"),
		pass_count = folder:GetAttribute("pass_count") or 0,
		fail_count = folder:GetAttribute("fail_count") or 0,
		error_count = folder:GetAttribute("error_count") or 0,
		started_at = folder:GetAttribute("started_at") or 0,
		finished_at = folder:GetAttribute("finished_at") or 0,
		lines = lines,
		payload = _payload,
	}
end

return TestSession
