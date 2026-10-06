-- GameSpy's first query protocol, which the Unreal Engine 1 games and others of their time speak: a TCP master that
-- challenges the client before it lists a game's servers, and \status\ to each server, answered in datagrams of
-- \key\value pairs numbered by \queryid\, \final\ in the last.

local Backslash = 92
local LowerI = 105
local LowerP = 112
local Dot = 46
local Colon = 58
local Space = 32
local Zero = 48
local Nine = 57
local Minus = 45
local Underscore = 95
local SecureMarker = "\\secure\\"
local SecureSize = 6
local EntryMarker = "\\ip\\"
local FinalMarker = "\\final\\"
local FatalMarker = "\\fatal\\"
-- 333networks' and OpenSpy's masters both take the key of the gspylite browser for listing any game.
local ClientGame = "gspylite"
local ClientKey = "mgNUaC"
local Base64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local StatusRequest = "\\status\\"
-- A server sends the datagrams of an answer within milliseconds; this leaves room for a slow link.
local QuietMs = 600
local MaxScore = 2147483647
local MaxPing = 4294967295
local MaxPort = 65535
local MaxOctet = 255
local MaxAddressSize = #"255.255.255.255:65535"
local MaxFieldDigits = 5
-- An index past this is no player's, and would cost its whole range to walk.
local MaxPlayerSlots = 1024
local PlayerNameKeys = { player = true, playername = true }
local PlayerScoreKeys = { frags = true, score = true }

local function hasAt(buffer, position, marker)
	return string.sub(buffer, position, position + #marker - 1) == marker
end

-- The buffer ends in the start of marker, so more is needed to tell.
local function isCutAt(buffer, position, marker)
	local remaining = #buffer - position + 1

	return remaining < #marker and string.sub(buffer, position) == string.sub(marker, 1, remaining)
end

-- Luigi Auriemma's gsmsalg, enctype 0, as 333networks' Masterserver-Qt5 implements it.
local function makeValidate(secure, key)
	local enc = {}
	local mixed = {}
	local a = 0
	local b = 0
	local out = {}

	for j = 0, 255 do
		enc[j] = j
	end

	for j = 0, 255 do
		a = (a + enc[j] + string.byte(key, j % #key + 1)) & 0xFF
		enc[a], enc[j] = enc[j], enc[a]
	end

	a = 0

	for i = 1, #secure do
		local c = string.byte(secure, i)

		a = (a + c + 1) & 0xFF

		local x = enc[a]

		b = (b + x) & 0xFF

		local y = enc[b]

		enc[b] = x
		enc[a] = y
		mixed[#mixed + 1] = c ~ enc[(x + y) & 0xFF]
	end

	while #mixed % 3 ~= 0 do
		mixed[#mixed + 1] = 0
	end

	for i = 1, #mixed, 3 do
		local x, y, z = mixed[i], mixed[i + 1], mixed[i + 2]

		for _, index in ipairs({ x >> 2, ((x & 3) << 4) | (y >> 4), ((y & 15) << 2) | (z >> 6), z & 63 }) do
			out[#out + 1] = string.sub(Base64, index + 1, index + 1)
		end
	end

	return table.concat(out)
end

-- Digits only, at most max; nil otherwise.
local function parseUnsigned(text, max)
	local value = (#text > 0) and 0 or nil

	for index = 1, #text do
		local byte = string.byte(text, index)

		value = (value ~= nil and byte >= Zero and byte <= Nine) and (value * 10 + byte - Zero) or nil
		value = (value ~= nil and value <= max) and value or nil
	end

	return value
end

-- As a server writes a number, spaces around it, a minus where allowed; nil when it is not one.
local function parseNumber(text, isSigned, max)
	local first = 1
	local last = #text

	while first <= last and string.byte(text, first) == Space do
		first = first + 1
	end

	while last >= first and string.byte(text, last) == Space do
		last = last - 1
	end

	local isNegative = isSigned and string.byte(text, first) == Minus
	local value = parseUnsigned(string.sub(text, isNegative and (first + 1) or first, last), isNegative and (max + 1) or max)

	return (value ~= nil and isNegative) and -value or value
end

-- "a.b.c.d:port" from first to last, or nil; read in place, since a master lists a thousand of them at once.
local function parseAddress(buffer, first, last)
	local isValid = last >= first and last - first + 1 <= MaxAddressSize
	local field = 1
	local value = 0
	local numDigits = 0
	local ip = 0
	local index = first

	while isValid and index <= last do
		local byte = string.byte(buffer, index)

		if byte >= Zero and byte <= Nine then
			value = value * 10 + byte - Zero
			numDigits = numDigits + 1
			isValid = numDigits <= MaxFieldDigits
		elseif (byte == Dot and field < 4) or (byte == Colon and field == 4) then
			isValid = numDigits > 0 and value <= MaxOctet
			ip = (ip << 8) | value
			field = field + 1
			value = 0
			numDigits = 0
		else
			isValid = false
		end

		index = index + 1
	end

	isValid = isValid and field == 5 and numDigits > 0 and value > 0 and value <= MaxPort

	return isValid and { ip = ip, port = value } or nil
end

-- The list's entries from position on: the servers, where reading stopped, and whether \final\ came or what is wrong.
local function readList(buffer, position, servers)
	local isFinal = false
	local reason = nil
	local isWaiting = false

	while not isFinal and reason == nil and not isWaiting and position <= #buffer do
		local b1, b2, b3, b4 = string.byte(buffer, position, position + 3)
		local isEntry = b1 == Backslash and b2 == LowerI and b3 == LowerP and b4 == Backslash
		local stop = isEntry and string.find(buffer, "\\", position + #EntryMarker, true) or nil

		if stop ~= nil then
			local server = parseAddress(buffer, position + #EntryMarker, stop - 1)

			reason = (server == nil) and "malformed" or nil
			servers[#servers + 1] = server
			position = stop
		elseif isEntry then
			isWaiting = true
		elseif hasAt(buffer, position, FinalMarker) then
			isFinal = true
		elseif hasAt(buffer, position, FatalMarker) then
			reason = "malformed"
		elseif isCutAt(buffer, position, FinalMarker) or isCutAt(buffer, position, EntryMarker) or isCutAt(buffer, position, FatalMarker) then
			isWaiting = true
		else
			reason = "malformed"
		end
	end

	return position, isFinal, reason
end

-- A datagram's \key\value pairs in order; nil when it does not start as one.
local function readPairs(datagram)
	local entries = {}
	local start = 2

	if string.byte(datagram, 1) ~= Backslash then
		return nil
	end

	while start <= #datagram do
		local keyEnd = string.find(datagram, "\\", start, true) or (#datagram + 1)
		local valueEnd = string.find(datagram, "\\", keyEnd + 1, true) or (#datagram + 1)

		entries[#entries + 1] = { key = string.sub(datagram, start, keyEnd - 1), value = string.sub(datagram, keyEnd + 1, valueEnd - 1) }
		start = valueEnd + 1
	end

	return entries
end

-- "frags_3" is player 3's frags; the field and the index, or nil when the key has no index.
local function splitPlayerKey(key)
	local underscore = nil
	local index = #key

	while index > 0 and string.byte(key, index) >= Zero and string.byte(key, index) <= Nine do
		index = index - 1
	end

	if index < #key and index > 1 and string.byte(key, index) == Underscore then
		underscore = index
	end

	return (underscore ~= nil) and string.sub(key, 1, underscore - 1) or nil, (underscore ~= nil) and parseUnsigned(string.sub(key, underscore + 1), MaxPlayerSlots - 1) or nil
end

local function readDatagram(state, entries)
	local part = 1

	for _, pair in ipairs(entries) do
		local field, index = splitPlayerKey(pair.key)

		if pair.key == "queryid" then
			local dot = string.find(pair.value, ".", 1, true)

			part = (dot ~= nil) and (parseUnsigned(string.sub(pair.value, dot + 1), MaxScore) or part) or part
		elseif pair.key == "final" then
			state.hasFinal = true
		elseif index ~= nil then
			local player = state.players[index] or {}

			player[field] = pair.value
			state.players[index] = player
			state.numPlayerSlots = math.max(state.numPlayerSlots, index + 1)
		elseif pair.key == "password" and (string.lower(pair.value) == "true" or string.lower(pair.value) == "false") then
			-- Unreal Engine 1 says True or False; the game's password rule reads a number.
			state.rules[#state.rules + 1] = { key = pair.key, value = (string.lower(pair.value) == "true") and "1" or "0" }
		else
			state.rules[#state.rules + 1] = pair
		end
	end

	state.parts[part] = true
	state.finalPart = (state.hasFinal and state.finalPart == nil) and part or state.finalPart
end

local function isComplete(state)
	local isEveryPart = state.finalPart ~= nil

	for part = 1, state.finalPart or 0 do
		isEveryPart = isEveryPart and state.parts[part] == true
	end

	return isEveryPart
end

local function makeReply(state)
	local players = {}
	local joinPort = nil

	for index = 0, state.numPlayerSlots - 1 do
		local fields = state.players[index] or {}
		local name = nil
		local score = nil

		for key, value in pairs(fields) do
			name = PlayerNameKeys[key] and value or name
			score = PlayerScoreKeys[key] and parseNumber(value, true, MaxScore) or score
		end

		if name ~= nil then
			players[#players + 1] = { name = name, score = score, ping = (fields.ping ~= nil) and parseNumber(fields.ping, false, MaxPing) or nil }
		end
	end

	for _, rule in ipairs(state.rules) do
		joinPort = (joinPort == nil and rule.key == "hostport") and parseNumber(rule.value, false, MaxPort) or joinPort
	end

	return { rules = state.rules, players = players, joinPort = (joinPort ~= nil and joinPort > 0) and joinPort or nil }
end

return {
	api = 2,
	version = 1,

	options = {
		masterGame = { required = true, description = "The game's name on the masters, such as \"ut\" or \"mohaa\"" },
	},

	master = {
		transport = "tcp",

		start = function(options, state)
			state.game = options.masterGame
			state.buffer = ""
			state.isListing = false
		end,

		-- The list is read from the next data on, the end of the stream included: a challenge answered sends only that.
		receive = function(state, data)
			local buffer = state.buffer .. data
			local secure = (not state.isListing) and string.find(buffer, SecureMarker, 1, true) or nil
			local challengeEnd = (secure ~= nil) and (secure + #SecureMarker + SecureSize - 1) or nil
			local action = nil

			if state.isListing then
				local servers = {}
				local position, isFinal, reason = readList(buffer, 1, servers)

				state.buffer = string.sub(buffer, position)
				action = { servers = servers, done = isFinal or nil, reason = (data == "" and not isFinal) and (reason or "truncated") or reason }
			elseif challengeEnd ~= nil and #buffer >= challengeEnd then
				state.isListing = true
				state.buffer = string.sub(buffer, challengeEnd + 1)
				action = { send = { "\\gamename\\" .. ClientGame .. "\\location\\0\\validate\\"
					.. makeValidate(string.sub(buffer, challengeEnd - SecureSize + 1, challengeEnd), ClientKey)
					.. "\\final\\\\list\\\\gamename\\" .. state.game .. "\\final\\" } }
			else
				state.buffer = buffer
				action = { reason = (data == "") and "truncated" or nil }
			end

			return action
		end,
	},

	server = {
		start = function(options, state)
			state.rules = {}
			state.players = {}
			state.numPlayerSlots = 0
			state.parts = {}
			state.seen = {}

			return { send = { StatusRequest } }
		end,

		-- A resent request is answered again, so a datagram already read is left out.
		receive = function(state, datagram)
			if state.seen[datagram] then
				return nil
			end

			local entries = readPairs(datagram)

			if entries == nil then
				return { reason = "wrongHeader" }
			end

			state.seen[datagram] = true
			readDatagram(state, entries)

			return isComplete(state) and { reply = makeReply(state) } or { quiet = QuietMs }
		end,

		finish = function(state)
			return next(state.seen) ~= nil and { reply = makeReply(state) } or nil
		end,
	},
}
