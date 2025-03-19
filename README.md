# Nexus Networking Module Documentation

## Overview

Nexus is a robust networking module for Roblox that provides type-strict, permission-based communication between server and clients. It offers features like message batching, rate limiting, and channel-based communication with fine-grained access control.

> **Note:** Nexus automatically initializes itself when required, so you can start using its functions immediately without calling a setup function.

## Key Features

- **Type-strict callbacks**: Ensures reliable communication with proper data types
- **Message batching**: Optimizes network performance by grouping messages
- **Rate limiting**: Prevents abuse through configurable rate limits
- **Access control**: Granular permissions for channel access
- **Size limiting**: Prevents oversized messages from causing issues
- **Bidirectional communication**: Server-to-client and client-to-server messaging
- **Auto-initialization**: The module sets itself up when required

## API Reference

### Core Functions

#### `Nexus.Setup(): boolean`

Although Nexus self-initializes when required, this function can be called explicitly if needed. Server creates the necessary RemoteEvents and RemoteFunctions, while clients connect to them.

```lua
local success = Nexus.Setup()
```

- Returns: `boolean` - Whether initialization was successful
- **Note:** This is called automatically when you require the module, so you typically don't need to call it manually.

#### `Nexus.Register(channelName: string, options): table?`

Creates a new communication channel or retrieves an existing one.

```lua
local channel = Nexus.Register("PlayerData", {
    rateLimit = 20,
    priority = 10,
    enableBatching = true,
    accessCheck = function(player)
        return player:GetRankInGroup(groupId) >= 10
    end
})
```

- Parameters:
  - `channelName`: String identifier for the channel
  - `options`: (Optional) Configuration table
    - `rateLimit`: Messages allowed per time window (default: 30)
    - `priority`: Channel priority from 1-10 (default: 5)
    - `maxPayloadSize`: Maximum message size in bytes (default: 100KB)
    - `batchInterval`: Time between batch processing (default: 1/60)
    - `enableBatching`: Whether to batch messages (default: true)
    - `accessCheck`: Function to determine player access

- Returns: Channel object or nil if creation failed

#### `Nexus.Connect(channelName: string, callback: Handler): boolean`

Subscribes to a channel and registers a callback for incoming messages.

```lua
Nexus.Connect("PlayerData", function(sender, data)
    print(sender, "sent:", data)
end)
```

- Parameters:
  - `channelName`: Channel to subscribe to
  - `callback`: Function to handle incoming messages
    - First parameter is always the sender ID
    - Remaining parameters are the message data

- Returns: `boolean` - Whether subscription was successful

#### `Nexus.Send(channelName: string, priority: number | any, ...: any): boolean`

Sends data through a channel to all subscribed clients.

```lua
-- With priority
Nexus.Send("PlayerData", 10, { userId = 123, score = 500 })

-- Without priority (uses channel default)
Nexus.Send("PlayerData", { userId = 123, score = 500 })
```

- Parameters:
  - `channelName`: Channel to send through
  - `priority`: Message priority or first data argument
  - `...`: Data to send (any serializable values)

- Returns: `boolean` - Whether the send operation was successful

### Advanced Configuration

#### `Nexus.AddFilter(channelName: string, func: FilterCallback): boolean`

Adds a filter function to a channel for validating messages.

```lua
Nexus.AddFilter("Chat", function(player, data)
    -- Block messages with bad words
    if containsBadWord(data[1]) then
        return true, "Message contains inappropriate content"
    end
    
    -- Allow message but sanitize it
    return false, nil, { sanitizeText(data[1]) }
end)
```

- Parameters:
  - `channelName`: Channel to add filter to
  - `func`: Filter function with signature `(player, data) -> (shouldCancel, reason?, modifiedData?)`
    - `shouldCancel`: Whether to block the message
    - `reason`: Optional reason for blocking
    - `modifiedData`: Optional modified data to use instead

- Returns: `boolean` - Whether filter was successfully added

#### `Nexus.SetAccess(channelName: string, func: AccessCheck): boolean`

Sets an access control function for a channel to determine who can subscribe.

```lua
Nexus.SetAccess("AdminCommands", function(player)
    return player:GetRankInGroup(groupId) >= 100
end)
```

- Parameters:
  - `channelName`: Channel to set access for
  - `func`: Function with signature `(player) -> boolean`

- Returns: `boolean` - Whether access function was successfully set

#### `Nexus.SetMaxPayloadSize(channelName: string, sizeInBytes: number): boolean`

Sets the maximum message size for a channel.

```lua
Nexus.SetMaxPayloadSize("LargeData", 500 * 1024) -- 500KB
```

- Parameters:
  - `channelName`: Channel to configure
  - `sizeInBytes`: Maximum message size in bytes

- Returns: `boolean` - Whether setting was applied

#### `Nexus.ConfigureBatching(channelName: string, options: {enable: boolean?, interval: number?}): boolean`

Configures message batching for a channel.

```lua
Nexus.ConfigureBatching("FrequentUpdates", {
    enable = true,
    interval = 1/30 -- 30 times per second
})
```

- Parameters:
  - `channelName`: Channel to configure
  - `options`: Batching options
    - `enable`: Whether to enable batching
    - `interval`: Time between batch processing

- Returns: `boolean` - Whether configuration was applied

## Types

```lua
type Payload = {[number]: any}
type Handler = (sender: string | number, ...any) -> ()
type FilterCallback = (player: Player, data: Payload) -> (boolean, string?, Payload?)
type AccessCheck = (player: Player) -> boolean
```

## Constants

- `RATE_LIMIT_WINDOW`: Time window for rate limiting (10 seconds)
- `DEFAULT_RATE_LIMIT`: Default calls per window (30)
- `DEFAULT_PRIORITY`: Default channel priority (5)
- `MAX_PAYLOAD_SIZE`: Maximum message size (100KB)
- `BATCH_INTERVAL`: Default batch interval (1/60 seconds)
- `MAX_BATCH_SIZE`: Maximum batch size (20 messages)

## Usage Examples

### Server-side Setup

```lua
local Nexus = require(ReplicatedStorage.Nexus)
-- Note: No need to call Nexus.Setup() as it's done automatically on require

-- Create a chat channel with access control
Nexus.Register("GlobalChat", {
    rateLimit = 10, -- 10 messages per 10 seconds
    accessCheck = function(player)
        return not player:GetAttribute("Muted")
    end
})

-- Listen for messages
Nexus.Connect("GlobalChat", function(senderId, message)
    local sender = Players:GetPlayerByUserId(senderId)
    print(sender.Name, "says:", message)
end)

-- Send server announcements
Nexus.Send("GlobalChat", 10, "Server is restarting in 5 minutes")
```

### Client-side Usage

```lua
local Nexus = require(ReplicatedStorage.Nexus)
-- Nexus is already initialized and will wait for server remotes

-- Connect to existing channel
Nexus.Connect("GlobalChat", function(senderId, message)
    if senderId == 0 then -- Server message
        print("ANNOUNCEMENT:", message)
    else
        local sender = Players:GetPlayerByUserId(senderId)
        print(sender.Name, "says:", message)
    end
end)

-- Send a message
local function sendChat(message)
    Nexus.Send("GlobalChat", message)
end

-- UI button connection
ChatButton.Activated:Connect(function()
    sendChat(ChatBox.Text)
    ChatBox.Text = ""
end)
```

### Creating a Private Channel

```lua
-- Team-specific channel
local function createTeamChannel(team)
    local channelName = "Team_" .. team.Name
    
    Nexus.Register(channelName, {
        accessCheck = function(player)
            return player.Team == team
        end
    })
    
    -- Team-specific announcements
    Nexus.Connect(channelName, function(senderId, message)
        print("Team message:", message)
    end)
end

-- Create channels for each team
for _, team in pairs(Teams:GetTeams()) do
    createTeamChannel(team)
end
```

## Best Practices

1. **Use appropriate rate limits**: Set rate limits based on expected usage patterns to prevent abuse.
2. **Set access controls**: Always implement access checks for sensitive channels.
3. **Filter incoming data**: Validate and sanitize user input to prevent exploits.
4. **Use batching for frequent updates**: Enable batching for channels with high-frequency, low-importance messages.
5. **Handle errors gracefully**: Use pcall around callbacks to prevent script errors from breaking functionality.
6. **Monitor payload sizes**: Be aware of message sizes to prevent performance issues.

## Troubleshooting

- **Channel not found**: Ensure the channel is registered before connecting or sending.
- **Connection failed**: Check that the client has permissions to access the channel.
- **Messages not receiving**: Verify that rate limits haven't been exceeded.
- **Performance issues**: Consider increasing batch intervals or reducing payload sizes.

## Limitations

- Maximum payload size is 100KB by default (configurable per channel)
- Rate limiting is based on a 10-second rolling window
- Instances and functions cannot be serialized in messages
