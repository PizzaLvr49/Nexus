-- Handles communication channels between the server and clients with type-strict callbacks.
-- Provides batching, rate limiting, and permission-based messaging.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

-- Type definitions for callbacks and messages
export type Payload = {[number]: any}
export type Handler = (sender: string | number, ...any) -> ()
export type FilterCallback = (player: Player, data: Payload) -> (boolean, string?, Payload?)
export type AccessCheck = (player: Player) -> boolean

local Nexus = {}

-- Constants
local RATE_LIMIT_WINDOW = 10 -- Time window for rate limiting
local DEFAULT_RATE_LIMIT = 30 -- Default call limit per window
local DEFAULT_PRIORITY = 5 -- Default channel priority (1-10)
local MAX_PAYLOAD_SIZE = 100 * 1024 -- 100KB max payload size
local BATCH_INTERVAL = 1/60 -- Default batch interval (60fps)
local MAX_BATCH_SIZE = 20 -- Maximum number of messages to batch together
local SERVER_ID = 0 -- Use 0 as a special ID for the server
local LOG_PREFIX = "[Nexus]" -- Consistent log prefix

-- Internal state
local isServer = RunService:IsServer()
local routes = {}
local remoteFolder
local initialized = false
local clientRateLimits = {} -- Keeps track of rate limits per user
local queue = {} -- For batching messages
local batchProcessConnection = nil -- Store connection for cleanup
local listeners = {} -- Track which players are subscribed to which channels

-- Logger functions for consistent output
local Logger = {
	Info = function(message, ...)
		print(LOG_PREFIX, message:format(...))
	end,

	Warn = function(message, ...)
		warn(LOG_PREFIX, message:format(...))
	end,

	Error = function(message, ...)
		error(LOG_PREFIX .. " " .. message:format(...), 2)
	end
}

-- Initializes the module (server creates remotes, clients wait for them)
function Nexus.Setup(): boolean
	if initialized then return true end

	if isServer then
		remoteFolder = Instance.new("Folder")
		remoteFolder.Name = "NexusRemotes"
		remoteFolder.Parent = ReplicatedStorage
	else
		remoteFolder = ReplicatedStorage:WaitForChild("NexusRemotes", 10)
		if not remoteFolder then
			Logger.Warn("Could not find remotes. Server may not have initialized yet.")
			return false
		end
	end

	initialized = true
	return true
end

-- Safely executes a callback function with pcall
local function safeCallback(callback: Handler, sender: string | number, ...: any): boolean
	local success, result = pcall(callback, sender, ...)
	if not success then
		Logger.Warn("Callback error: %s", result)
	end
	return success
end

-- Calculates the approximate size of a Lua value in bytes
local function approximateSize(value): number
	local valueType = typeof(value)

	if valueType == "nil" then
		return 0
	elseif valueType == "boolean" then
		return 1
	elseif valueType == "number" then
		return 8
	elseif valueType == "string" then
		return #value
	elseif valueType == "table" then
		local size = 0
		for k, v in pairs(value) do
			size = size + approximateSize(k) + approximateSize(v)
		end
		return size
	elseif valueType == "userdata" or valueType == "function" or valueType == "thread" then
		return 8 -- Pointer size, approximate
	elseif valueType == "Instance" then
		return #tostring(value) -- Approximation based on string representation
	end

	return 8 -- Default fallback
end

-- Checks if a message exceeds size limits
local function checkSizeLimit(message: Payload): (boolean, number)
	local totalSize = approximateSize(message)
	return totalSize <= MAX_PAYLOAD_SIZE, totalSize
end

-- Checks if a user has exceeded rate limits
local function checkRateLimit(channelName: string, playerOrUserId): boolean
	if not isServer then return true end 

	local userId
	if typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player") then
		userId = playerOrUserId.UserId
	else
		userId = tonumber(playerOrUserId) or tostring(playerOrUserId)
	end

	clientRateLimits[channelName] = clientRateLimits[channelName] or {}
	clientRateLimits[channelName][userId] = clientRateLimits[channelName][userId] or { count = 0, lastReset = tick() }

	local playerData = clientRateLimits[channelName][userId]
	local now = tick()

	if now - playerData.lastReset >= RATE_LIMIT_WINDOW then
		playerData.count = 0
		playerData.lastReset = now
	end

	if playerData.count >= (routes[channelName] and routes[channelName].rateLimit or DEFAULT_RATE_LIMIT) then
		return false
	end

	playerData.count += 1
	return true
end

-- Creates a batch key for message batching
local function getBatchKey(channelName: string, priority: number): string
	if isServer then
		return channelName .. "_server_" .. priority
	else
		return channelName .. "_" .. (Players.LocalPlayer and Players.LocalPlayer.UserId or "client") .. "_" .. priority
	end
end

-- Processes message batches
local function processQueue()
	for batchKey, batch in pairs(queue) do
		if #batch.messages > 0 then
			local channelName = batch.channelName
			local channelFolder = remoteFolder:FindFirstChild(channelName)
			if not channelFolder then continue end

			local sendEvent = channelFolder:FindFirstChild("Send") :: RemoteEvent
			if not sendEvent then continue end

			-- Sort messages by priority (higher numbers = higher priority)
			table.sort(batch.messages, function(a, b)
				return a.priority > b.priority
			end)

			-- Extract just the data to send
			local dataToSend = {}
			for _, msg in ipairs(batch.messages) do
				table.insert(dataToSend, msg.data)
			end

			-- Check combined size
			local withinLimit, totalSize = checkSizeLimit(dataToSend)
			if not withinLimit then
				Logger.Warn("Batch for channel '%s' exceeds size limit (%d bytes). Sending messages individually.", channelName, totalSize)
				-- Send messages individually when batch is too large
				for _, msg in ipairs(batch.messages) do
					local withinIndividualLimit = checkSizeLimit(msg.data)
					if withinIndividualLimit then
						if isServer then
							-- Only send to authorized listeners
							for playerId, channelList in pairs(listeners) do
								if channelList[channelName] then
									local player = Players:GetPlayerByUserId(playerId)
									if player then
										sendEvent:FireClient(player, msg.sender, table.unpack(msg.data))
									end
								end
							end

							-- Local server callbacks
							if routes[channelName] then
								for _, callback in ipairs(routes[channelName].handlers) do
									task.spawn(function()
										safeCallback(callback, msg.sender, table.unpack(msg.data))
									end)
								end
							end
						else
							sendEvent:FireServer(table.unpack(msg.data))
						end
					else
						Logger.Warn("Message in channel '%s' exceeds size limit.", channelName)
					end
				end
			else
				-- Send as batch
				if isServer then
					-- Send each message separately to each listener
					for playerId, channelList in pairs(listeners) do
						if channelList[channelName] then
							local player = Players:GetPlayerByUserId(playerId)
							if player then
								-- Send each message separately without batch wrapper
								for _, singleData in ipairs(dataToSend) do
									sendEvent:FireClient(player, SERVER_ID, table.unpack(singleData))
								end
							end
						end
					end

					-- Local server callbacks - also process each message individually
					if routes[channelName] then
						for _, singleData in ipairs(dataToSend) do
							for _, callback in ipairs(routes[channelName].handlers) do
								task.spawn(function()
									safeCallback(callback, SERVER_ID, table.unpack(singleData))
								end)
							end
						end
					end
				else
					sendEvent:FireServer({batch = dataToSend})
				end
			end

			batch.messages = {}
		end
	end
end

-- Set up batch processing with Heartbeat (works on both server and client)
local lastBatchTime = tick()
local function setupBatchProcessing()
	if batchProcessConnection then
		batchProcessConnection:Disconnect()
	end

	batchProcessConnection = RunService.Heartbeat:Connect(function()
		local now = tick()
		-- Only process batches at the configured interval
		if now - lastBatchTime >= BATCH_INTERVAL then
			processQueue()
			lastBatchTime = now
		end
	end)
end

-- Creates a new communication channel (both server and client)
function Nexus.Register(channelName: string, options): {}?
	if not Nexus.Setup() then return nil end

	if routes[channelName] then
		-- If the channel already exists and has options, preserve the access check
		if options and options.accessCheck and typeof(options.accessCheck) == "function" then
			routes[channelName].accessCheck = options.accessCheck
		end
		return routes[channelName]
	end

	options = options or {}

	-- Create channel folder on server, or find it from client
	local channelFolder

	if isServer then
		channelFolder = Instance.new("Folder")
		channelFolder.Name = channelName
		channelFolder.Parent = remoteFolder

		local sendEvent = Instance.new("RemoteEvent")
		sendEvent.Name = "Send"
		sendEvent.Parent = channelFolder

		local connectFunction = Instance.new("RemoteFunction")
		connectFunction.Name = "Connect"
		connectFunction.Parent = channelFolder
	else
		-- Clients can also create channels, but they need to wait for server acknowledgment
		local createChannelRemote = remoteFolder:FindFirstChild("CreateChannel")
		if not createChannelRemote then
			-- Create the remote for client channel creation if it doesn't exist
			if not isServer then
				Logger.Warn("Client attempted to create channel but server support is not initialized")
				return nil
			end
		end

		-- Request channel creation from server
		if not isServer then
			local success = false

			-- Wait for server to acknowledge
			channelFolder = remoteFolder:FindFirstChild(channelName)
			if not channelFolder then
				-- Send request to create if doesn't exist
				local createRemote = remoteFolder:FindFirstChild("CreateChannel") :: RemoteFunction
				if createRemote then
					success = createRemote:InvokeServer(channelName, options)
					if success then
						channelFolder = remoteFolder:WaitForChild(channelName, 5)
					end
				end

				if not success or not channelFolder then
					Logger.Warn("Client failed to create channel '%s'", channelName)
					return nil
				end
			end
		end
	end

	if not channelFolder and not isServer then
		channelFolder = remoteFolder:WaitForChild(channelName, 5)
		if not channelFolder then
			Logger.Warn("Could not find or create channel '%s'", channelName)
			return nil
		end
	end

	local channel = {
		name = channelName,
		rateLimit = options.rateLimit or DEFAULT_RATE_LIMIT,
		priority = options.priority or DEFAULT_PRIORITY,
		maxPayloadSize = options.maxPayloadSize or MAX_PAYLOAD_SIZE,
		batchInterval = options.batchInterval or BATCH_INTERVAL,
		enableBatching = options.enableBatching ~= false, -- Default to true
		filterFunc = nil,
		accessCheck = options.accessCheck, -- Store the access check function
		handlers = {},
		owner = isServer and SERVER_ID or (Players.LocalPlayer and Players.LocalPlayer.UserId or "Client"),
		remotes = { 
			sendEvent = isServer and channelFolder:FindFirstChild("Send") or nil,
			connectFunction = isServer and channelFolder:FindFirstChild("Connect") or nil
		}
	}

	if isServer then
		local sendEvent = channel.remotes.sendEvent

		-- Handle messages from clients
		sendEvent.OnServerEvent:Connect(function(player: Player, ...)
			if not checkRateLimit(channelName, player) then return end

			local args = {...}

			-- Handle batched messages
			if type(args[1]) == "table" and args[1].batch then
				for _, batchedData in ipairs(args[1].batch) do
					local withinLimit = checkSizeLimit(batchedData)
					if not withinLimit then
						continue -- Skip oversized messages
					end

					local shouldCancel, cancelReason, modifiedData = false, nil, nil

					if channel.filterFunc then
						pcall(function()
							shouldCancel, cancelReason, modifiedData = channel.filterFunc(player, batchedData)
						end)
					end

					if not shouldCancel then
						local dataToSend = modifiedData or batchedData

						-- Broadcast to all listeners
						for playerId, channelList in pairs(listeners) do
							if channelList[channelName] then
								local targetPlayer = Players:GetPlayerByUserId(playerId)
								if targetPlayer and targetPlayer ~= player then -- Don't echo back to sender
									if type(dataToSend) == "table" then
										sendEvent:FireClient(targetPlayer, player.UserId, table.unpack(dataToSend))
									else
										sendEvent:FireClient(targetPlayer, player.UserId, dataToSend)
									end
								end
							end
						end

						-- Notify server-side handlers
						for _, callback in ipairs(channel.handlers) do
							task.spawn(function()
								if type(dataToSend) == "table" then
									safeCallback(callback, player.UserId, table.unpack(dataToSend))
								else
									safeCallback(callback, player.UserId, dataToSend)
								end
							end)
						end
					elseif cancelReason then
						Logger.Info("Batched message from %s was blocked: %s", player.Name, cancelReason)
					end
				end
				return
			end

			-- Handle regular messages
			local withinLimit = checkSizeLimit(args)
			if not withinLimit then
				Logger.Warn("Message from %s in channel '%s' exceeds size limit.", player.Name, channelName)
				return
			end

			local shouldCancel, cancelReason, modifiedArgs = false, nil, nil

			if channel.filterFunc then
				pcall(function()
					shouldCancel, cancelReason, modifiedArgs = channel.filterFunc(player, args)
				end)
			end

			if shouldCancel then
				if cancelReason then
					Logger.Info("Message from %s was blocked: %s", player.Name, cancelReason)
				end
				return
			end

			local argsToSend = modifiedArgs or args

			-- Broadcast to all listeners
			for playerId, channelList in pairs(listeners) do
				if channelList[channelName] then
					local targetPlayer = Players:GetPlayerByUserId(playerId)
					if targetPlayer and targetPlayer ~= player then -- Don't echo back to sender
						if #argsToSend > 0 then
							sendEvent:FireClient(targetPlayer, player.UserId, table.unpack(argsToSend))
						else
							sendEvent:FireClient(targetPlayer, player.UserId)
						end
					end
				end
			end

			-- Notify server-side handlers
			for _, callback in ipairs(routes[channelName].handlers) do
				task.spawn(function()
					if #argsToSend > 0 then
						safeCallback(callback, player.UserId, table.unpack(argsToSend))
					else
						safeCallback(callback, player.UserId)
					end
				end)
			end
		end)

		-- Handle subscription requests
		local connectFunction = channel.remotes.connectFunction
		connectFunction.OnServerInvoke = function(player)
			-- Add debugging output
			Logger.Info("Player %s attempting to connect to channel %s", player.Name, channelName)

			-- Check if player has permission to subscribe
			if channel.accessCheck then
				local hasPermission = false
				local success, errorMsg = pcall(function()
					hasPermission = channel.accessCheck(player)
				end)

				Logger.Info("Access check result for %s: %s", player.Name, tostring(hasPermission))

				if not success then
					Logger.Warn("Error in access check: %s", errorMsg)
					return false, "Access check error: " .. tostring(errorMsg)
				end

				if not hasPermission then
					Logger.Info("Access denied for %s", player.Name)
					return false, "Access denied"
				end
			else
				Logger.Info("No access check for channel %s - granting access", channelName)
			end

			-- Record the subscription
			local userId = player.UserId
			listeners[userId] = listeners[userId] or {}
			listeners[userId][channelName] = true

			Logger.Info("Access granted for %s to channel %s", player.Name, channelName)
			return true
		end

		-- Create a remote function for client channel creation if it doesn't exist
		if not remoteFolder:FindFirstChild("CreateChannel") then
			local createChannelRemote = Instance.new("RemoteFunction")
			createChannelRemote.Name = "CreateChannel"
			createChannelRemote.Parent = remoteFolder

			createChannelRemote.OnServerInvoke = function(player, requestedChannelName, requestedOptions)
				-- Basic validation
				if type(requestedChannelName) ~= "string" or #requestedChannelName < 1 then
					return false
				end

				-- Don't allow client to override server channels
				if routes[requestedChannelName] then
					-- If the channel exists, but the client requests options, 
					-- we should apply their accessCheck (fixes the issue)
					if requestedOptions and requestedOptions.accessCheck and typeof(requestedOptions.accessCheck) == "function" then
						-- Check if the client is allowed to modify this channel
						if routes[requestedChannelName].owner == player.UserId then
							routes[requestedChannelName].accessCheck = requestedOptions.accessCheck
						end
					end
					return true -- Pretend success if channel exists already
				end

				-- Create the channel
				local options = requestedOptions or {}

				-- Only set default access check if none was provided
				if options.accessCheck == nil then
					options.accessCheck = function(p)
						-- Default to allowing creator plus server to use the channel
						return p.UserId == player.UserId or p:GetRankInGroup(game.CreatorId) >= 254
					end
				end

				Nexus.Register(requestedChannelName, options)
				return true
			end
		end
	else
		-- For client-side registration, make sure we have a way to set the accessCheck
		-- when the channel is registered server-side
		if options and options.accessCheck and typeof(options.accessCheck) == "function" then
			-- We'll try to apply this once we connect
			Nexus.SetAccess(channelName, options.accessCheck)
		end
	end

	routes[channelName] = channel
	return channel
end

-- Sets a filter function for a channel
function Nexus.AddFilter(channelName: string, func: FilterCallback): boolean
	if not routes[channelName] then
		Logger.Warn("Channel '%s' does not exist.", channelName)
		return false
	end

	-- Check if we own this channel
	local channelOwner = routes[channelName].owner
	local currentUser = isServer and SERVER_ID or (Players.LocalPlayer and Players.LocalPlayer.UserId or "Client")

	if channelOwner ~= currentUser and isServer == false then
		Logger.Warn("Only the channel owner can set filter functions.")
		return false
	end

	routes[channelName].filterFunc = func
	return true
end

-- Sets access control function for a channel
function Nexus.SetAccess(channelName: string, func: AccessCheck): boolean
	Logger.Info("Setting access for channel: %s", channelName)

	-- Create the channel if it doesn't exist yet
	if not routes[channelName] then
		if isServer then
			Nexus.Register(channelName, {accessCheck = func})
			return true
		else
			Logger.Warn("Channel '%s' does not exist.", channelName)
			return false
		end
	end

	-- Check if we own this channel
	local channelOwner = routes[channelName].owner
	local currentUser = isServer and SERVER_ID or (Players.LocalPlayer and Players.LocalPlayer.UserId or "Client")

	Logger.Info("Channel owner: %s, Current user: %s", tostring(channelOwner), tostring(currentUser))

	if channelOwner ~= currentUser and isServer == false then
		Logger.Warn("Only the channel owner can set access functions.")
		return false
	end

	-- Apply the access function
	routes[channelName].accessCheck = func
	Logger.Info("Access function set successfully for channel: %s", channelName)

	-- If we're on the client and need to inform the server about this change
	if not isServer then
		-- Try to update the server's version of the access function
		local channelFolder = remoteFolder:FindFirstChild(channelName)
		if channelFolder then
			local createRemote = remoteFolder:FindFirstChild("CreateChannel") :: RemoteFunction
			if createRemote then
				local success = createRemote:InvokeServer(channelName, {accessCheck = func})
				Logger.Info("Server update of access function result: %s", tostring(success))
			end
		end
	end

	return true
end

-- Sends data through a channel (broadcasts to all listeners)
function Nexus.Send(channelName: string, priority: number | any, ...: any): boolean
	if not Nexus.Setup() then return false end

	local channelFolder = remoteFolder:FindFirstChild(channelName)
	if not channelFolder then
		Logger.Warn("Channel '%s' not found.", channelName)
		return false
	end

	local sendEvent = channelFolder:FindFirstChild("Send") :: RemoteEvent
	if not sendEvent then return false end

	-- Handle priority parameter (if omitted, shift args)
	local actualPriority: number
	local args = {...}

	if type(priority) == "number" then
		actualPriority = priority
	else
		actualPriority = (routes[channelName] and routes[channelName].priority) or DEFAULT_PRIORITY
		table.insert(args, 1, priority)
	end

	-- Check payload size
	local withinLimit, size = checkSizeLimit(args)
	if not withinLimit then
		Logger.Warn("Message to channel '%s' exceeds size limit (%d bytes).", channelName, size)
		return false
	end

	-- Check if channel has batching enabled
	local shouldBatch = routes[channelName] and routes[channelName].enableBatching
	if shouldBatch then
		local batchKey = getBatchKey(channelName, actualPriority)

		if not queue[batchKey] then
			queue[batchKey] = {
				channelName = channelName,
				messages = {}
			}
		end

		table.insert(queue[batchKey].messages, {
			sender = isServer and SERVER_ID or (Players.LocalPlayer and Players.LocalPlayer.UserId or "Client"),
			priority = actualPriority,
			data = args
		})

		-- If batch is full, process immediately
		if #queue[batchKey].messages >= MAX_BATCH_SIZE then
			processQueue()
		end

		return true
	end

	-- Non-batched sending
	if isServer then
		-- Broadcast to all listeners
		for playerId, channelList in pairs(listeners) do
			if channelList[channelName] then
				local player = Players:GetPlayerByUserId(playerId)
				if player then
					if #args > 0 then
						sendEvent:FireClient(player, SERVER_ID, table.unpack(args))
					else
						sendEvent:FireClient(player, SERVER_ID)
					end
				end
			end
		end

		-- Server-side callbacks
		for _, callback in ipairs(routes[channelName].handlers) do
			task.spawn(function()
				if #args > 0 then
					safeCallback(callback, SERVER_ID, table.unpack(args))
				else
					safeCallback(callback, SERVER_ID)
				end
			end)
		end
	else
		if #args > 0 then
			sendEvent:FireServer(table.unpack(args))
		else
			sendEvent:FireServer()
		end
	end

	return true
end

-- Subscribes to a channel with typed callback
function Nexus.Connect(channelName: string, callback: Handler): boolean
	if not Nexus.Setup() then return false end

	local channelFolder = remoteFolder:FindFirstChild(channelName)
	if not channelFolder then
		Logger.Warn("Channel '%s' does not exist.", channelName)
		return false
	end

	local sendEvent = channelFolder:FindFirstChild("Send") :: RemoteEvent

	if isServer then
		routes[channelName] = routes[channelName] or { 
			name = channelName, 
			rateLimit = DEFAULT_RATE_LIMIT,
			priority = DEFAULT_PRIORITY,
			maxPayloadSize = MAX_PAYLOAD_SIZE,
			batchInterval = BATCH_INTERVAL,
			enableBatching = true,
			filterFunc = nil,
			accessCheck = nil,
			handlers = {},
			owner = SERVER_ID,
			remotes = { sendEvent = sendEvent, connectFunction = nil }
		}
		table.insert(routes[channelName].handlers, callback)
	else
		local success = false
		local errorMessage = nil

		pcall(function()
			local connectFunction = channelFolder:FindFirstChild("Connect") :: RemoteFunction
			success, errorMessage = connectFunction:InvokeServer()
		end)

		if not success then
			Logger.Warn("Connection to channel '%s' failed: %s", channelName, errorMessage or "Unknown error")
			return false
		end

		-- Track local subscription
		local userId = Players.LocalPlayer.UserId
		listeners[userId] = listeners[userId] or {}
		listeners[userId][channelName] = true

		sendEvent.OnClientEvent:Connect(function(sender: string | number, ...)
			-- Handle batched messages
			local args = {...}
			if sender == SERVER_ID and type(args[1]) == "table" and args[1].batch then
				for _, batchedData in ipairs(args[1].batch) do
					if type(batchedData) == "table" then
						safeCallback(callback, sender, table.unpack(batchedData))
					else
						safeCallback(callback, sender, batchedData)
					end
				end
				return
			end

			-- Handle regular messages
			safeCallback(callback, sender, ...)
		end)

		-- Create local channel object if it doesn't exist
		if not routes[channelName] then
			routes[channelName] = {
				name = channelName,
				handlers = {},
				owner = "Client"
			}
		end

		-- Add local callback
		table.insert(routes[channelName].handlers, callback)
	end

	return true
end

-- Set max payload size (for advanced control)
function Nexus.SetMaxPayloadSize(channelName: string, sizeInBytes: number): boolean
	if not routes[channelName] then
		Logger.Warn("Channel '%s' does not exist.", channelName)
		return false
	end

	routes[channelName].maxPayloadSize = sizeInBytes
	return true
end

-- Configure batching for a channel
function Nexus.ConfigureBatching(channelName: string, options: {enable: boolean?, interval: number?}): boolean
	if not routes[channelName] then
		Logger.Warn("Channel '%s' does not exist.", channelName)
		return false
	end

	if options.enable ~= nil then
		routes[channelName].enableBatching = options.enable
	end

	if options.interval then
		routes[channelName].batchInterval = options.interval
		-- Update the batch interval timing
		BATCH_INTERVAL = math.min(BATCH_INTERVAL, options.interval)
	end

	return true
end

-- Cleans up when a player leaves
if isServer then
	Players.PlayerRemoving:Connect(function(player)
		for _, data in pairs(clientRateLimits) do
			data[player.UserId] = nil
		end

		-- Remove player from subscriptions
		listeners[player.UserId] = nil
	end)
end

-- Cleanup when the game ends
if isServer then
	game:BindToClose(function()
		if batchProcessConnection then
			batchProcessConnection:Disconnect()
		end
	end)
end

-- Start the batch processing
setupBatchProcessing()

Nexus.Setup()

return Nexus
