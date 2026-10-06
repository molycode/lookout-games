-- The Quake II engine family, Kingpin's among them: query to a master, status to each server.

local Prefix = "\xFF\xFF\xFF\xFF"
local MasterQuery = "query"
local MasterReplyHeader = Prefix .. "servers"
local StatusReplyHeader = Prefix .. "print\n"
local AddressSize = 6
local MasterQuietMs = 1500
local Backslash = 92
local Newline = 10
local Space = 32
local Minus = 45
local Zero = 48
local Nine = 57
local MaxScore = 2147483647
local MaxPing = 4294967295

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

-- <score> <ping> "<name>"; some mods put more numbers before the name, so the name is what the quotes enclose. Alien
-- Arena puts more after it, and no name holds a quote: Info_SetValueForKey refuses one.
local function parsePlayerLine(line)
	local nameStart = string.find(line, "\"", 1)
	local nameEnd = (nameStart ~= nil) and string.find(line, "\"", nameStart + 1) or nil
	local last = (nameStart ~= nil) and (nameStart - 1) or #line
	local score, afterScore = parseNumber(line, 1, last, true, MaxScore)
	local ping = (score ~= nil) and parseNumber(line, afterScore, last, false, MaxPing) or nil

	if nameStart == nil or nameEnd == nil or ping == nil then
		return nil
	end

	return { name = string.sub(line, nameStart + 1, nameEnd - 1), score = score, ping = ping }
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

	return reply
end

-- Kingpin's master separates the header from the list with a newline, the Quake 2 masters with a space.
local function parseMasterDatagram(datagram)
	local servers = {}
	local separator = string.byte(datagram, #MasterReplyHeader + 1)

	if not startsWith(datagram, MasterReplyHeader) or (separator ~= Newline and separator ~= Space) then
		return servers, "wrongHeader"
	end

	local position = #MasterReplyHeader + 2

	while #datagram - position + 1 >= AddressSize do
		servers[#servers + 1] = readAddress(datagram, position)
		position = position + AddressSize
	end

	if position <= #datagram then
		return servers, "truncated"
	end

	return servers
end

local function parseStatusDatagram(datagram)
	if not startsWith(datagram, StatusReplyHeader) then
		return nil, "wrongHeader"
	end

	return parseStatusBody(string.sub(datagram, #StatusReplyHeader + 1))
end

return {
	api = 2,
	version = 1,

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
			return { send = { Prefix .. "status\n" } }
		end,

		receive = function(state, datagram)
			local reply, reason = parseStatusDatagram(datagram)

			return { reply = reply, reason = reason }
		end,
	},
}
