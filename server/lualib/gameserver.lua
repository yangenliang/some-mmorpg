local gateserver = require "gateserver"
local skynet = require "skynet"
local logger = require "logger"
local sprotoloader = require "sprotoloader"

local gameserver = {}
local handshake = {}

function gameserver.forward (fd, agent)
	gateserver.forward (fd, agent)
end

function gameserver.kick (fd)
	gateserver.close_client (fd)
end

function gameserver.start (gamed)
	local handler = {}

	local host = sprotoloader.load (1):host "package"
	local send_request = host:attach (sprotoloader.load (2))

	function handler.open (source, conf)
		return gamed.open (conf.name)
	end

	function handler.connect (fd, addr)
		logger.log (string.format ("connect from %s (fd = %d)", addr, fd))
		handshake[fd] = addr
		gateserver.open_client (fd)
	end

	function handler.disconnect (fd)
		logger.log (string.format ("fd (%d) disconnected", fd))
	end

	local function do_login (msg, sz)
		local type, name, args, response = host:dispatch (msg, sz)
		assert (type == "REQUEST")
		assert (name == "login")
		local account = assert (tonumber (args.account))
		local token = assert (args.token)
		local ok = gamed.auth_handler (account, token)
		assert (ok == true)
		return account
	end

	function handler.message (fd, msg, sz)
		local addr = handshake[fd]

		if addr then
			handshake[fd] = nil
			local ok, account = pcall (do_login, msg, sz)
			if not ok then
				logger.log (string.format ("%s login failed", addr))
				gateserver.close_client (fd)
			else
				logger.log (string.format ("account %d login success", account))
				gamed.login_handler (fd, account)
			end
		else
			gamed.message_handler (fd, msg, sz)
		end
	end

	local CMD = {}

	function CMD.token (id, secret)
		local id = tonumber (id)
		login_token[id] = secret
		skynet.timeout (10 * 100, function ()
			if login_token[id] == secret then
				logger.debug (string.format ("account %d token timeout", id))
				login_token[id] = nil
			end
		end)
	end

	function handler.command (cmd, ...)
		local f = CMD[cmd]
		if f then
			return f (...)
		else
			return gamed.command_handler (cmd, ...)
		end
	end

	return gateserver.start (handler)
end

return gameserver
