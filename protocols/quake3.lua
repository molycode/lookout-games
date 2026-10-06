-- The Quake III Arena family: getservers from a master, getstatus from each server, and getinfo from a server whose
-- status leaves out a rule the game takes from it.

local Prefix = "\xFF\xFF\xFF\xFF"
local MasterReplyHeader = Prefix .. "getserversResponse"
local StatusReplyHeader = Prefix .. "statusResponse\n"
local InfoReplyHeader = Prefix .. "infoResponse\n"
-- The server only echoes the word back as the info's challenge.
local InfoRequest = Prefix .. "getinfo lookout"
local EchoHeader = Prefix .. "echo \""
local EchoChallenge = "echoResponse getstatus "
-- Call of Duty's masters end their last datagram with "\EOF".
local EndMarkers = { ["\\EOT"] = true, ["\\EOF"] = true }
local EndMarkerSize = 4
local MasterQuietMs = 1500
local Backslash = 92
local Space = 32
local Newline = 10
local Nul = 0
local Quote = 34
local Minus = 45
local Zero = 48
local Nine = 57
local UpperA = 65
local UpperF = 70
local LowerA = 97
local LowerF = 102
local MaxScore = 2147483647
local MaxPing = 4294967295
local MaxCount = 4294967295
-- Each entry is a backslash and then the address, so an address byte that happens to be a backslash is harmless.
local EntrySize = 7
-- Elite Force's masters write the address and port as twelve hex digits.
local HexEntrySize = 13
local HexEntries = "hex"

local function startsWith(text, prefix)
	return string.sub(text, 1, #prefix) == prefix
end

local function readAddress(datagram, position)
	local ip, port = string.unpack(">I4I2", datagram, position)

	return { ip = ip, port = port }
end

local function isHexDigit(byte)
	return (byte >= Zero and byte <= Nine) or (byte >= UpperA and byte <= UpperF) or (byte >= LowerA and byte <= LowerF)
end

-- nil unless all twelve are hex digits.
local function readHexAddress(datagram, position)
	local isHex = true

	for index = position, position + HexEntrySize - 2 do
		isHex = isHex and isHexDigit(string.byte(datagram, index))
	end

	return isHex and { ip = tonumber(string.sub(datagram, position, position + 7), 16), port = tonumber(string.sub(datagram, position + 8, position + 11), 16) } or nil
end

-- An end marker with nothing but NUL padding after it; a 69.79.84.x entry starts with the same four bytes. The
-- Tremulous and Unvanquished masters end each datagram with a lone backslash instead.
local function isEndOfList(datagram, position, remaining, entrySize)
	local isLoneBackslash = remaining == 1 and string.byte(datagram, position) == Backslash

	return isLoneBackslash or (remaining <= entrySize and EndMarkers[string.sub(datagram, position, position + EndMarkerSize - 1)] == true
		and string.sub(datagram, position + EndMarkerSize) == string.rep("\0", remaining - EndMarkerSize))
end

-- Call of Duty's masters put a newline and a NUL before the first entry, JK2MV's a newline, Elite Force's a space.
local function skipLeadIn(datagram, position)
	local byte = string.byte(datagram, position)

	while byte == Newline or byte == Nul or byte == Space do
		position = position + 1
		byte = string.byte(datagram, position)
	end

	return position
end

-- "15,16 empty full" asks for each protocol version in turn, as JK2MV and CoD2x do.
local function makeMasterQueries(masterQuery)
	local comma = string.find(masterQuery, ",", 1, true)
	local queries = {}

	if comma == nil then
		queries[1] = Prefix .. "getservers " .. masterQuery
	else
		local wordStart = comma
		local wordEnd = (string.find(masterQuery, " ", comma, true) or (#masterQuery + 1)) - 1

		while wordStart > 1 and string.byte(masterQuery, wordStart - 1) ~= Space do
			wordStart = wordStart - 1
		end

		local partStart = wordStart

		while partStart <= wordEnd + 1 do
			local partEnd = string.find(masterQuery, ",", partStart, true)

			partEnd = (partEnd ~= nil and partEnd <= wordEnd) and partEnd or (wordEnd + 1)
			assert(partEnd > partStart, "masterQuery lists an empty protocol version")
			queries[#queries + 1] = Prefix .. "getservers " .. string.sub(masterQuery, 1, wordStart - 1)
				.. string.sub(masterQuery, partStart, partEnd - 1) .. string.sub(masterQuery, wordEnd + 1)
			partStart = partEnd + 1
		end
	end

	return queries
end

-- The text an OpenJK server asks to have echoed before it answers getstatus, or nil.
local function readEchoChallenge(datagram)
	local text = (startsWith(datagram, EchoHeader) and string.byte(datagram, #datagram) == Quote)
		and string.sub(datagram, #EchoHeader + 1, #datagram - 1) or ""

	return startsWith(text, EchoChallenge) and text or nil
end

-- "\key\value" pairs up to the end of info; false when info is not one.
local function parseInfo(info, rules)
	local isValid = string.byte(info, 1) == Backslash
	local start = 2

	while isValid and start <= #info do
		local keyEnd = string.find(info, "\\", start)

		isValid = keyEnd ~= nil

		if isValid then
			local valueEnd = string.find(info, "\\", keyEnd + 1)
			local valueLast = (valueEnd ~= nil) and (valueEnd - 1) or #info

			rules[#rules + 1] = { key = string.sub(info, start, keyEnd - 1), value = string.sub(info, keyEnd + 1, valueLast) }
			start = (valueEnd ~= nil) and (valueEnd + 1) or (#info + 1)
		end
	end

	return isValid
end

-- As std::from_chars reads it: spaces skipped, a minus only where allowed, at least one digit, never out of range.
-- Returns the number and the position after it, or nil.
local function parseNumber(line, position, last, isSigned, max)
	local index = position

	while index <= last and string.byte(line, index) == Space do
		index = index + 1
	end

	local isNegative = isSigned and index <= last and string.byte(line, index) == Minus
	local limit = isNegative and (max + 1) or max
	local value = 0
	local digitsStart = 0

	if isNegative then
		index = index + 1
	end

	digitsStart = index

	local byte = (index <= last) and string.byte(line, index) or nil

	while value ~= nil and byte ~= nil and byte >= Zero and byte <= Nine do
		value = value * 10 + (byte - Zero)

		if value > limit then
			value = nil
		end

		index = index + 1
		byte = (index <= last) and string.byte(line, index) or nil
	end

	if value == nil or index == digitsStart then
		return nil
	end

	return isNegative and -value or value, index
end

-- <score> <ping> "<name>"; some mods put more numbers before the name, so the name is what the quotes enclose.
local function parsePlayerLine(line)
	local nameStart = string.find(line, "\"", 1)
	local nameEnd = nameStart
	local quote = (nameStart ~= nil) and string.find(line, "\"", nameStart + 1) or nil

	while quote ~= nil do
		nameEnd = quote
		quote = string.find(line, "\"", quote + 1)
	end

	local last = (nameStart ~= nil) and (nameStart - 1) or #line
	local score, afterScore = parseNumber(line, 1, last, true, MaxScore)
	local ping = (score ~= nil) and parseNumber(line, afterScore, last, true, MaxPing) or nil

	if nameStart == nil or nameEnd == nameStart or ping == nil then
		return nil
	end

	-- Call of Duty's servers give a player still connecting a ping of -1.
	return { name = string.sub(line, nameStart + 1, nameEnd - 1), score = score, ping = (ping >= 0) and ping or nil }
end

-- The rule's value, whatever case the server spells its name in, or nil.
local function findRule(rules, key)
	local wanted = string.lower(key)
	local value = nil

	for _, rule in ipairs(rules) do
		value = (value == nil and string.lower(rule.key) == wanted) and rule.value or value
	end

	return value
end

-- The slots players can take: the private ones are kept for those who know sv_privatePassword.
local function setCapacity(reply)
	local maxClients = findRule(reply.rules, "sv_maxclients")
	local privateClients = findRule(reply.rules, "sv_privateClients")
	local numSlots = (maxClients ~= nil) and parseNumber(maxClients, 1, #maxClients, false, MaxCount) or nil
	local numPrivate = (privateClients ~= nil) and parseNumber(privateClients, 1, #privateClients, false, MaxCount) or nil

	if numSlots ~= nil then
		reply.maxPlayers = math.max(numSlots - (numPrivate or 0), 0)
	end
end

local function parseStatusBody(body)
	local infoEnd = string.find(body, "\n", 1)
	local reply = { rules = {}, players = {}, malformedPlayerLines = 0 }

	if not parseInfo(string.sub(body, 1, (infoEnd ~= nil) and (infoEnd - 1) or #body), reply.rules) then
		return nil, "malformed"
	end

	local position = (infoEnd ~= nil) and (infoEnd + 1) or (#body + 1)

	while position <= #body do
		local lineEnd = string.find(body, "\n", position) or (#body + 1)

		if lineEnd > position then
			local player = parsePlayerLine(string.sub(body, position, lineEnd - 1))

			if player ~= nil then
				reply.players[#reply.players + 1] = player
			else
				reply.malformedPlayerLines = reply.malformedPlayerLines + 1
			end
		end

		position = lineEnd + 1
	end

	setCapacity(reply)

	return reply
end

local function parseMasterDatagram(datagram, isHex)
	local servers = {}
	local entrySize = isHex and HexEntrySize or EntrySize

	if not startsWith(datagram, MasterReplyHeader) then
		return servers, "wrongHeader"
	end

	local position = skipLeadIn(datagram, #MasterReplyHeader + 1)

	while position <= #datagram do
		local remaining = #datagram - position + 1
		local server = nil

		if isEndOfList(datagram, position, remaining, entrySize) then
			position = #datagram + 1
		elseif string.byte(datagram, position) ~= Backslash then
			return servers, "malformed"
		elseif remaining < entrySize then
			return servers, "truncated"
		else
			if isHex then
				server = readHexAddress(datagram, position + 1)
			else
				server = readAddress(datagram, position + 1)
			end

			if server == nil then
				return servers, "malformed"
			end

			servers[#servers + 1] = server
			position = position + entrySize
		end
	end

	return servers
end

local function parseStatusDatagram(datagram)
	if not startsWith(datagram, StatusReplyHeader) then
		return nil, "wrongHeader"
	end

	return parseStatusBody(string.sub(datagram, #StatusReplyHeader + 1))
end

-- The words of text, split at spaces.
local function splitWords(text)
	local words = {}
	local start = 1

	while start <= #text do
		local stop = string.find(text, " ", start, true) or (#text + 1)

		if stop > start then
			words[#words + 1] = string.sub(text, start, stop - 1)
		end

		start = stop + 1
	end

	return words
end

-- Those of keys the reply's rules leave out.
local function findMissingRules(reply, keys)
	local missing = {}

	for _, key in ipairs(keys) do
		if findRule(reply.rules, key) == nil then
			missing[#missing + 1] = key
		end
	end

	return missing
end

-- Each of keys that the info gives, added to the reply's rules; a malformed info adds nothing.
local function addInfoRules(reply, keys, datagram)
	local body = string.sub(datagram, #InfoReplyHeader + 1)
	local lineEnd = string.find(body, "\n", 1, true)
	local info = {}

	if parseInfo(string.sub(body, 1, (lineEnd ~= nil) and (lineEnd - 1) or #body), info) then
		for _, key in ipairs(keys) do
			local value = findRule(info, key)

			if value ~= nil then
				reply.rules[#reply.rules + 1] = { key = key, value = value }
			end
		end
	end

	return reply
end

return {
	api = 2,
	version = 1,

	options = {
		masterQuery = { required = true, description = "The words after getservers: the protocol number, then filters such as \"empty full\"; "
			.. "several numbers joined by commas, such as \"15,16 empty full\", ask for each" },
		masterEntries = { required = false, description = "\"hex\" when the master writes each address as twelve hex digits, as Elite Force's do" },
		infoRules = { required = false, description = "Rules, separated by spaces, that getstatus leaves out and getinfo gives, such as RTCW's "
			.. "g_needpass; a server whose status lacks one is asked getinfo as well" },
	},

	master = {
		transport = "udp",

		start = function(options, state)
			assert(options.masterEntries == nil or options.masterEntries == HexEntries, "masterEntries must be \"hex\" when given")
			state.isHex = options.masterEntries == HexEntries

			return { send = makeMasterQueries(options.masterQuery) }
		end,

		-- \EOT never means done: UDP may deliver it before the datagrams sent ahead of it.
		receive = function(state, datagram)
			local servers, reason = parseMasterDatagram(datagram, state.isHex)

			return { servers = servers, reason = reason, quiet = MasterQuietMs }
		end,
	},

	server = {
		start = function(options, state)
			state.infoRules = splitWords(options.infoRules or "")

			return { send = { Prefix .. "getstatus" } }
		end,

		-- The challenge is answered once; a second one, to a resent getstatus, is ignored. A status that lacks an info
		-- rule is kept until the info comes, and a second status, to a resent getstatus, is ignored then.
		receive = function(state, datagram)
			local challenge = readEchoChallenge(datagram)

			if challenge ~= nil then
				local isFirst = not state.hasEchoed

				state.hasEchoed = true

				return isFirst and { send = { Prefix .. challenge } } or nil
			end

			if state.reply ~= nil then
				return startsWith(datagram, InfoReplyHeader) and { reply = addInfoRules(state.reply, state.missingRules, datagram) } or nil
			end

			local reply, reason = parseStatusDatagram(datagram)
			local missingRules = (reply ~= nil) and findMissingRules(reply, state.infoRules) or {}

			if #missingRules > 0 then
				state.reply = reply
				state.missingRules = missingRules

				return { send = { InfoRequest } }
			end

			return { reply = reply, reason = reason }
		end,

		-- Only a kept status gets here with something to give: its info never came, so the reply lacks just those rules.
		finish = function(state)
			return (state.reply ~= nil) and { reply = state.reply } or nil
		end,
	},
}
