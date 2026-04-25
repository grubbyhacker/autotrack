--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))

type MemoryEntry = Types.MemoryEntry
type RunMemory = Types.RunMemory

local EnduranceMemory = {}

local LIMITS = {
	shared = 8,
	orchestrator = 6,
	proposal = 6,
	repair = 6,
}

local _entryCounter = 0

local function cloneEntry(entry: MemoryEntry): MemoryEntry
	return {
		entry_id = entry.entry_id,
		author = entry.author,
		scope = entry.scope,
		note = entry.note,
		confidence = entry.confidence,
		source_type = entry.source_type,
		source_ref = entry.source_ref,
		timestamp = entry.timestamp,
	}
end

function EnduranceMemory.new(): RunMemory
	return {
		shared = {},
		orchestrator = {},
		proposal = {},
		repair = {},
	}
end

function EnduranceMemory.clone(memory: RunMemory?): RunMemory
	local source = memory or EnduranceMemory.new()
	local result = EnduranceMemory.new()
	for scopeName, entries in pairs(source) do
		if type(entries) == "table" and result[scopeName] ~= nil then
			for _, entry in ipairs(entries) do
				table.insert(result[scopeName], cloneEntry(entry))
			end
		end
	end
	return result
end

function EnduranceMemory.nextEntryId(author: string): string
	_entryCounter += 1
	return string.format("%s-memory-%03d", author, _entryCounter)
end

function EnduranceMemory.append(memory: RunMemory, scopeName: string, entry: MemoryEntry)
	local bucket = memory[scopeName]
	assert(type(bucket) == "table", "unknown memory scope: " .. tostring(scopeName))
	table.insert(bucket, 1, cloneEntry(entry))
	local limit = LIMITS[scopeName] or 6
	while #bucket > limit do
		table.remove(bucket)
	end
end

function EnduranceMemory.shouldSkipDuplicate(memory: RunMemory, scopeName: string, entry: MemoryEntry): boolean
	local bucket = memory[scopeName]
	if type(bucket) ~= "table" then
		return false
	end
	for _, existing in ipairs(bucket) do
		if
			existing.author == entry.author
			and existing.scope == entry.scope
			and existing.source_type == entry.source_type
			and existing.note == entry.note
		then
			return true
		end
	end
	return false
end

function EnduranceMemory.appendSharedIfFresh(memory: RunMemory, entry: MemoryEntry): boolean
	if EnduranceMemory.shouldSkipDuplicate(memory, "shared", entry) then
		return false
	end
	EnduranceMemory.append(memory, "shared", entry)
	return true
end

function EnduranceMemory.latestNotes(memory: RunMemory?, scopeName: string, count: number): { string }
	local bucket = memory and memory[scopeName]
	local notes = {}
	if type(bucket) ~= "table" then
		return notes
	end
	for index = 1, math.min(count, #bucket) do
		table.insert(notes, bucket[index].note)
	end
	return notes
end

function EnduranceMemory.depth(memory: RunMemory?, scopeName: string): number
	local bucket = memory and memory[scopeName]
	if type(bucket) ~= "table" then
		return 0
	end
	return #bucket
end

return EnduranceMemory
