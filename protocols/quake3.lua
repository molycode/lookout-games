-- The Quake III Arena family: getservers from a master, getstatus from each server.

local Prefix = "\xFF\xFF\xFF\xFF"
local MasterReplyHeader = Prefix .. "getserversResponse"
local StatusReplyHeader = Prefix .. "statusResponse\n"
local EndOfList = "\\EOT"
local MasterQuietMs = 1500
local Backslash = 92
local Space = 32
local Minus = 45
local Zero = 48
local Nine = 57
local MaxScore = 2147483647
local MaxPing = 4294967295
-- Each entry is a backslash and then the address, so an address byte that happens to be a backslash is harmless.
local EntrySize = 7

local function startsWith(text, prefix)
	return string.sub(text, 1, #prefix) == prefix
end

local function readAddress(datagram, position)
	local ip, port = string.unpack(">I4I2", datagram, position)

	return { ip = ip, port = port }
end

-- "\EOT" with nothing but NUL padding after it; a 69.79.84.x entry starts with the same four bytes.
local function isEndOfList(datagram, position, remaining)
	return remaining <= EntrySize and string.sub(datagram, position, position + #EndOfList - 1) == EndOfList
		and string.sub(datagram, position + #EndOfList) == string.rep("\0", remaining - #EndOfList)
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
	local ping = (score ~= nil) and parseNumber(line, afterScore, last, false, MaxPing) or nil

	if nameStart == nil or nameEnd == nameStart or ping == nil then
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

local function parseMasterDatagram(datagram)
	local servers = {}

	if not startsWith(datagram, MasterReplyHeader) then
		return servers, "wrongHeader"
	end

	local position = #MasterReplyHeader + 1

	while position <= #datagram do
		local remaining = #datagram - position + 1

		if isEndOfList(datagram, position, remaining) then
			position = #datagram + 1
		elseif string.byte(datagram, position) ~= Backslash then
			return servers, "malformed"
		elseif remaining < EntrySize then
			return servers, "truncated"
		else
			servers[#servers + 1] = readAddress(datagram, position + 1)
			position = position + EntrySize
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

return {
	api = 1,

	options = {
		masterQuery = { required = true, description = "The words after getservers: the protocol number, then filters such as \"empty full\"" },
	},

	master = {
		transport = "udp",

		start = function(options, state)
			return { send = { Prefix .. "getservers " .. options.masterQuery } }
		end,

		-- \EOT never means done: UDP may deliver it before the datagrams sent ahead of it.
		receive = function(state, datagram)
			local servers, reason = parseMasterDatagram(datagram)

			return { servers = servers, reason = reason, quiet = MasterQuietMs }
		end,
	},

	server = {
		start = function(options, state)
			return { send = { Prefix .. "getstatus" } }
		end,

		receive = function(state, datagram)
			local reply, reason = parseStatusDatagram(datagram)

			return { reply = reply, reason = reason }
		end,
	},
}
