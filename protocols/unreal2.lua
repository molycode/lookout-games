-- Unreal Engine 2's server query (UT2004 and its kin) and its TCP master. A server answers each command in packets
-- that carry no count and no end, so it is done once it falls quiet. Latin-1 text and colour codes (ESC R G B) pass
-- through as sent, for the game's text style to decode, since servers send UTF-8 in them too; UTF-16 becomes UTF-8.

local QueryHeader = "\x79\x00\x00\x00"
local InfoCommand = 0
local RulesCommand = 1
local PlayersCommand = 2
local ReplyHeaderSize = 5
-- A server sends all the packets of an answer within milliseconds; this leaves room for a slow link.
local QuietMs = 600
local Escape = 0x1B
local ColourCodeSize = 4
local MaxCompactIndexBytes = 5
local RedTeamBit = 0x20000000
local BlueTeamBit = 0x40000000

local ClientName = "UT2K4CLIENT"
local ClientVersion = 3369
local Language = "int"
-- No master checks the CD key hashes, so zeros stand in for them.
local KeyHash = string.rep("0", 32)
local MaxFrameSize = 65536

-- Reads in order; past the end it marks itself truncated and every later read gives nil.
local function newReader(data, position)
	return { data = data, position = position, isTruncated = false }
end

local function take(reader, format, size)
	if reader.isTruncated or reader.position + size - 1 > #reader.data then
		reader.isTruncated = true

		return nil
	end

	local value = string.unpack(format, reader.data, reader.position)

	reader.position = reader.position + size

	return value
end

-- Bit 7 of the first byte is the sign and bit 6 says more follow; each later byte adds 7 bits, bit 7 saying more follow.
local function takeCompactIndex(reader)
	local first = take(reader, "B", 1)

	if first == nil then
		return nil
	end

	local value = first & 0x3F
	local hasMore = first & 0x40 ~= 0
	local shift = 6
	local numBytes = 1

	while hasMore and numBytes < MaxCompactIndexBytes do
		local byte = take(reader, "B", 1)

		if byte == nil then
			return nil
		end

		value = value | ((byte & 0x7F) << shift)
		hasMore = byte & 0x80 ~= 0
		shift = shift + 7
		numBytes = numBytes + 1
	end

	if hasMore then
		reader.isTruncated = true

		return nil
	end

	return (first & 0x80 ~= 0) and -value or value
end

-- In a wide string each part of a colour code is a whole code unit, of which only the low byte counts.
local function appendUtf16(parts, data, first, numUnits)
	local index = 0

	while index < numUnits do
		local unit = string.unpack("<I2", data, first + 2 * index)

		if unit == Escape and index + ColourCodeSize - 1 < numUnits then
			local red, green, blue = string.unpack("<I2I2I2", data, first + 2 * (index + 1))

			parts[#parts + 1] = string.char(Escape, red & 0xFF, green & 0xFF, blue & 0xFF)
			index = index + ColourCodeSize
		elseif unit >= 0xD800 and unit <= 0xDBFF and index + 1 < numUnits then
			local low = string.unpack("<I2", data, first + 2 * (index + 1))
			local isPair = low >= 0xDC00 and low <= 0xDFFF

			parts[#parts + 1] = utf8.char(isPair and (0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)) or 0xFFFD)
			index = index + (isPair and 2 or 1)
		else
			parts[#parts + 1] = utf8.char((unit >= 0xD800 and unit <= 0xDFFF) and 0xFFFD or unit)
			index = index + 1
		end
	end
end

-- A positive length counts Latin-1 bytes, a negative one UTF-16 code units; either counts the closing NUL.
local function takeString(reader)
	local length = takeCompactIndex(reader)

	if length == nil or length == 0 then
		return (length == 0) and "" or nil
	end

	local size = (length < 0) and (-length * 2) or length

	if reader.position + size - 1 > #reader.data then
		reader.isTruncated = true

		return nil
	end

	local first = reader.position

	reader.position = reader.position + size

	if length > 0 then
		return string.sub(reader.data, first, first + length - 2)
	end

	local parts = {}

	appendUtf16(parts, reader.data, first, -length - 1)

	return table.concat(parts)
end

local function addRule(rules, key, value)
	rules[#rules + 1] = { key = key, value = tostring(value) }
end

local function readInfo(reader, state)
	take(reader, "<i4", 4)
	takeString(reader)

	local port = take(reader, "<i4", 4)

	take(reader, "<i4", 4)

	local name = takeString(reader)
	local map = takeString(reader)
	local gameType = takeString(reader)
	local numPlayers = take(reader, "<i4", 4)
	local maxPlayers = take(reader, "<i4", 4)

	take(reader, "<i4", 4)
	take(reader, "<i4", 4)

	local skill = takeString(reader)

	if reader.isTruncated then
		return false
	end

	addRule(state.info, "hostname", name)
	addRule(state.info, "map", map)
	addRule(state.info, "gametype", gameType)
	addRule(state.info, "numplayers", numPlayers)
	addRule(state.info, "maxplayers", maxPlayers)
	addRule(state.info, "skill", skill)
	state.joinPort = (port >= 1 and port <= 65535) and port or nil
	state.hasInfo = true

	return true
end

-- GamePassword appears only when a password is set.
local function readRules(reader, state)
	while not reader.isTruncated and reader.position <= #reader.data do
		local key = takeString(reader)
		local value = takeString(reader)

		if not reader.isTruncated then
			addRule(state.rules, key, value)
			state.hasPassword = state.hasPassword or (key == "GamePassword" and value == "True")
		end
	end

	return not reader.isTruncated
end

-- Mutators add entries with id 0 and no ping, such as team labels; a real player can have id 0, but never no ping.
local function readPlayers(reader, state)
	while not reader.isTruncated and reader.position <= #reader.data do
		local id = take(reader, "<i4", 4)
		local name = takeString(reader)
		local ping = take(reader, "<i4", 4)
		local score = take(reader, "<i4", 4)
		local statsId = take(reader, "<I4", 4)

		if not reader.isTruncated and not (id == 0 and ping == 0) then
			local player = { name = name, score = score, ping = (ping >= 0) and ping or nil }

			if statsId & RedTeamBit ~= 0 then
				player.fields = { { key = "Team", value = "Red" } }
			elseif statsId & BlueTeamBit ~= 0 then
				player.fields = { { key = "Team", value = "Blue" } }
			end

			state.players[#state.players + 1] = player
		end
	end

	return not reader.isTruncated
end

-- For the client's own short ASCII strings, whose length fits the first byte of a compact index.
local function makeString(text)
	return string.pack("B", #text + 1) .. text .. "\0"
end

local function makeFrame(payload)
	return string.pack("<I4", #payload) .. payload
end

local ClientResponse = makeFrame(makeString(KeyHash) .. makeString(KeyHash) .. makeString(ClientName) .. string.pack("<I4B", ClientVersion, 0)
	.. makeString(Language) .. string.pack("<I4I4I4B", 0, 0, 0, 0))
local Verification = makeFrame(makeString(KeyHash))
local ListRequest = makeFrame("\0\0")

-- One frame of the master's conversation, by the stage it reached; a reply to send, if any.
local function readFrame(state, payload, servers)
	local reader = newReader(payload, 1)
	local reply = nil

	if state.stage == "challenge" then
		state.stage = "approval"
		reply = ClientResponse
	elseif state.stage == "approval" then
		local verdict = takeString(reader)

		assert(verdict == "APPROVED", "the master answered " .. tostring(verdict))
		state.stage = "verification"
		reply = Verification
	elseif state.stage == "verification" then
		local verdict = takeString(reader)

		assert(verdict == "VERIFIED", "the master answered " .. tostring(verdict))
		state.stage = "count"
		reply = ListRequest
	elseif state.stage == "count" then
		state.numExpected = take(reader, "<I4", 4)
		state.stage = "servers"
	else
		local ip = take(reader, ">I4", 4)

		take(reader, "<I2", 2)

		local queryPort = take(reader, "<I2", 2)

		assert(not reader.isTruncated, "a server entry was cut short")
		servers[#servers + 1] = { ip = ip, port = queryPort }
		state.numListed = state.numListed + 1
	end

	return reply
end

return {
	api = 1,

	master = {
		transport = "tcp",

		start = function(options, state)
			state.buffer = ""
			state.stage = "challenge"
			state.numListed = 0
		end,

		receive = function(state, data)
			if data == "" then
				local isComplete = state.stage == "servers" and state.buffer == "" and state.numListed >= state.numExpected

				return isComplete and { done = true } or { reason = "truncated" }
			end

			local buffer = state.buffer .. data
			local position = 1
			local servers = {}
			local send = {}
			local isReading = true

			while isReading do
				local size = (#buffer - position + 1 >= 4) and string.unpack("<I4", buffer, position) or nil

				assert(size == nil or size <= MaxFrameSize, "a frame larger than any master sends")
				isReading = size ~= nil and #buffer - position + 1 >= 4 + size

				if isReading then
					send[#send + 1] = readFrame(state, string.sub(buffer, position + 4, position + 3 + size), servers)
					position = position + 4 + size
				end
			end

			state.buffer = string.sub(buffer, position)

			if state.stage == "servers" and state.numListed >= state.numExpected then
				return { servers = servers, done = true }
			end

			return { servers = servers, send = (#send > 0) and send or nil }
		end,
	},

	server = {
		start = function(options, state)
			state.info = {}
			state.rules = {}
			state.players = {}
			state.hasPassword = false
			state.seen = {}

			return { send = { QueryHeader .. "\0", QueryHeader .. "\1", QueryHeader .. "\2" } }
		end,

		-- Only the info packet answers: without it a resend asks again, and what was already read comes back the same.
		receive = function(state, datagram)
			if #datagram < ReplyHeaderSize or state.seen[datagram] then
				return nil
			end

			state.seen[datagram] = true

			local command = string.byte(datagram, 5)
			local reader = newReader(datagram, ReplyHeaderSize + 1)
			local isRead = nil

			if command == InfoCommand then
				isRead = readInfo(reader, state)
			elseif command == RulesCommand then
				isRead = readRules(reader, state)
			elseif command == PlayersCommand then
				isRead = readPlayers(reader, state)
			end

			if isRead == false then
				return { reason = "malformed" }
			end

			return state.hasInfo and { quiet = QuietMs } or nil
		end,

		finish = function(state)
			if not state.hasInfo then
				return nil
			end

			-- Info rules first, as packets may come in any order and a rule is found by its first match.
			local rules = state.info

			table.move(state.rules, 1, #state.rules, #rules + 1, rules)
			addRule(rules, "password", state.hasPassword and 1 or 0)

			return { reply = { rules = rules, players = state.players, joinPort = state.joinPort } }
		end,
	},
}
