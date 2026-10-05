-- QuakeWorld: c to a master, status to each server, as ezQuake asks for them.

local Prefix = "\xFF\xFF\xFF\xFF"
local MasterQuery = "c\n"
local MasterReplyHeader = Prefix .. "d\n"
-- Server info, players, spectators and teams, the bits MVDSV's SVC_Status reads; older servers send everyone.
local StatusRequest = Prefix .. "status 23\n"
local StatusReplyHeader = Prefix .. "n"
local SpectatorPrefix = "\\s\\"
local AddressSize = 6
local NumLeadingNumbers = 4
local MasterQuietMs = 1500
local Backslash = 92
local Space = 32
local Minus = 45
local Zero = 48
local Nine = 57
local Nul = 0
local MaxNumber = 2147483647

local function startsWith(text, prefix)
	return string.sub(text, 1, #prefix) == prefix
end

local function readAddress(datagram, position)
	local ip, port = string.unpack(">I4I2", datagram, position)

	return { ip = ip, port = port }
end

-- "\key\value" pairs up to the end of info; false when info is not one.
local function parseInfo(info, rules)
	local isValid = string.byte(info, 1) == Backslash
	local start = 2

	while isValid and start <= #info do
		local keyEnd = string.find(info, "\\", start, true)

		isValid = keyEnd ~= nil

		if isValid then
			local valueEnd = string.find(info, "\\", keyEnd + 1, true)
			local valueLast = (valueEnd ~= nil) and (valueEnd - 1) or #info

			rules[#rules + 1] = { key = string.sub(info, start, keyEnd - 1), value = string.sub(info, keyEnd + 1, valueLast) }
			start = (valueEnd ~= nil) and (valueEnd + 1) or (#info + 1)
		end
	end

	return isValid
end

-- Spaces skipped, a minus allowed, at least one digit, never out of range; the number and the position after it,
-- or nil.
local function parseNumber(line, position, last)
	local index = position

	while index <= last and string.byte(line, index) == Space do
		index = index + 1
	end

	local isNegative = index <= last and string.byte(line, index) == Minus
	local limit = isNegative and (MaxNumber + 1) or MaxNumber
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

-- The first count numbers of a line up to last, or nil when one is missing.
local function parseLeadingNumbers(line, last, count)
	local numbers = {}
	local position = 1

	while position ~= nil and #numbers < count do
		local value, after = parseNumber(line, position, last)

		numbers[#numbers + 1] = value
		position = (value ~= nil) and after or nil
	end

	return (#numbers == count) and numbers or nil
end

-- <userid> <frags> <time> <ping> "<name>" "<skin>" <top> <bottom> ["<team>"]; no name holds a quote. A spectator's
-- ping is negative and MVDSV marks its name with \s\; nil when the line is not a player's.
local function parsePlayerLine(line)
	local nameStart = string.find(line, "\"", 1, true)
	local nameEnd = (nameStart ~= nil) and string.find(line, "\"", nameStart + 1, true) or nil
	local numbers = parseLeadingNumbers(line, (nameStart ~= nil) and (nameStart - 1) or #line, NumLeadingNumbers)

	if nameEnd == nil or numbers == nil then
		return nil
	end

	local name = string.sub(line, nameStart + 1, nameEnd - 1)

	return { name = name, score = numbers[2], ping = numbers[4], isSpectator = numbers[4] < 0 or startsWith(name, SpectatorPrefix) }
end

-- Spectators are left out: maxclients counts only players.
local function parseStatusBody(body)
	local infoEnd = string.find(body, "\n", 1, true)
	local reply = { rules = {}, players = {}, malformedPlayerLines = 0 }

	if not parseInfo(string.sub(body, 1, (infoEnd ~= nil) and (infoEnd - 1) or #body), reply.rules) then
		return nil, "malformed"
	end

	local position = (infoEnd ~= nil) and (infoEnd + 1) or (#body + 1)

	while position <= #body do
		local lineEnd = string.find(body, "\n", position, true) or (#body + 1)

		if lineEnd > position then
			local player = parsePlayerLine(string.sub(body, position, lineEnd - 1))

			if player == nil then
				reply.malformedPlayerLines = reply.malformedPlayerLines + 1
			elseif not player.isSpectator then
				reply.players[#reply.players + 1] = { name = player.name, score = player.score, ping = player.ping }
			end
		end

		position = lineEnd + 1
	end

	return reply
end

local function parseMasterDatagram(datagram)
	local servers = {}

	if not startsWith(datagram, MasterReplyHeader) then
		return servers, "wrongHeader"
	end

	local position = #MasterReplyHeader + 1

	while #datagram - position + 1 >= AddressSize do
		servers[#servers + 1] = readAddress(datagram, position)
		position = position + AddressSize
	end

	if position <= #datagram then
		return servers, "truncated"
	end

	return servers
end

-- Some servers end the reply with a NUL.
local function parseStatusDatagram(datagram)
	local last = (string.byte(datagram, #datagram) == Nul) and (#datagram - 1) or #datagram

	if not startsWith(datagram, StatusReplyHeader) then
		return nil, "wrongHeader"
	end

	return parseStatusBody(string.sub(datagram, #StatusReplyHeader + 1, last))
end

return {
	api = 1,

	master = {
		transport = "udp",

		start = function(options, state)
			return { send = { MasterQuery } }
		end,

		-- The list has no end marker, so it ends once the master has been quiet a while.
		receive = function(state, datagram)
			local servers, reason = parseMasterDatagram(datagram)

			return { servers = servers, reason = reason, quiet = MasterQuietMs }
		end,
	},

	server = {
		start = function(options, state)
			return { send = { StatusRequest } }
		end,

		receive = function(state, datagram)
			local reply, reason = parseStatusDatagram(datagram)

			return { reply = reply, reason = reason }
		end,
	},
}
