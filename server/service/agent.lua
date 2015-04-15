local skynet = require "skynet"
local queue = require "skynet.queue"
local logger = require "logger"
local sprotoloader = require "sprotoloader"
local sharemap = require "sharemap"
local socket = require "socket"
local character_handler = require "handler.character_handler"
local world_handler = require "handler.world_handler"
local map_handler = require "handler.map_handler"
local aoi_handler = require "handler.aoi_handler"

local gamed = ...
local database

local host = sprotoloader.load (3):host "package"
local pack_request = host:attach (sprotoloader.load (4))

--[[
.user {
	fd : integer
	account : integer
	character : character

	world : integer
	map : integer
}
]]

local user

local function send_msg (fd, msg)
	local package = string.pack (">s2", msg)
	socket.write (fd, package)
end

local user_fd
local session = {}
local session_id = 0
local function send_request (name, args)
	session_id = session_id + 1
	local str = pack_request (name, args, session_id)
	send_msg (user_fd, str)
	session[session_id] = { name = name, args = args }
end

local function kick_self ()
	skynet.call (gamed, "lua", "kick", skynet.self (), user_fd)
end

local last_heartbeat_time
local HEARTBEAT_TIME_MAX = 0 -- 60 * 100
local function heartbeat_check ()
	if HEARTBEAT_TIME_MAX <= 0 or not user_fd then return end

	local t = last_heartbeat_time + HEARTBEAT_TIME_MAX - skynet.now ()
	if t <= 0 then
		logger.warning ("heatbeat check failed")
		kick_self ()
	else
		skynet.timeout (t, heartbeat_check)
	end
end

local REQUEST
local function handle_request (name, args, response)
	local f = REQUEST[name]
	if f then
		local ok, ret = pcall (f, user, args)
		if not ok then
			logger.warning (string.format ("handle message failed : %s", name), ret) 
			kick_self ()
		else
			last_heartbeat_time = skynet.now ()
			if response and ret then
				send_msg (user_fd, response (ret))
			end
		end
	else
		logger.warning (string.format ("unhandled message : %s", name)) 
		kick_self ()
	end
end

skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
	unpack = function (msg, sz)
		return host:dispatch (msg, sz)
	end,
	dispatch = function (_, _, type, ...)
		if type == "REQUEST" then
			handle_request (...)
		else
			print ("invalid message type", type)
		end
	end,
}

local CMD = {}


function CMD.open (from, fd, account)
	local name = string.format ("agnet%d-a-%d", skynet.self (), account)
	logger.register (name)
	logger.debug ("agent opened")

	user = { 
		fd = fd, 
		account = account,
		REQUEST = {},
		send_request = send_request
	}
	user_fd = user.fd
	REQUEST = user.REQUEST
	character_handler.register (user)

	last_heartbeat_time = skynet.now ()
	heartbeat_check ()
end

function CMD.close ()
	logger.debug ("agent closed")
	
	local account
	if user then
		account = user.account

		if user.map then
			skynet.call (user.map, "lua", "character_leave")
			user.map = nil
		end

		if user.world then
			skynet.call (user.world, "lua", "character_leave", user.character.id)
			user.world = nil
		end

		character_handler.save (user.character)

		user = nil
		user_fd = nil
		REQUEST = nil
	end

	skynet.call (gamed, "lua", "close", self, account)
end

function CMD.kick ()
	logger.debug ("agent kicked")
	skynet.call (gamed, "lua", "kick", skynet.self (), user_fd)
end

function CMD.world_enter (world)
	local name = string.format ("agnet%d-c-%d", skynet.self (), user.character.id)
	logger.register (name)
	logger.debug (string.format ("world(%d) entered", world))

	character_handler.init (user.character)

	user.world = world
	character_handler.unregister (user)
	world_handler.register (user)

	return user.character.general.map, user.character.movement.pos
end

function CMD.map_enter (map)
	logger.debug (string.format ("map(%d) entered", map))
	
	user.map = map

	map_handler.register (user)
	aoi_handler.register (user)
end

skynet.start (function ()
	skynet.dispatch ("lua", function (_, from, command, ...)
		local f = CMD[command]
		if f then
			skynet.retpack (f (from, ...))
		else
			f = assert (REQUEST[command])
			local ok, ret = pcall (f, user, ...)
			if not ok then
				logger.warning (string.format ("handle message failed : %s", command), ret) 
				kick_self ()
			end
			skynet.retpack (ret)
		end
	end)
end)

