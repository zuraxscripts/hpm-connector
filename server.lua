--[[
    HMP Connector Resource
    Communicates with the HappinessMP Management Panel.
    Sends player data, resource states, handles kick/ban from panel.
    Uses action queue pattern to avoid Thread.Create nesting errors.
]]

-- ==================== Configuration ====================
local PANEL_HOST = "http://127.0.0.1:8080"
local PANEL_SECRET = "changeme"  -- Must match panel_config.json panel_secret
local SEND_CHAT_MESSAGES = false -- Set true to also send panel messages to in-game chat

-- ==================== State ====================
local connectedPlayers = {}  -- serverID -> { name, ip, session, joinTime }
local actionQueue = {}       -- Actions queued from HTTP callbacks, processed in heartbeat thread

-- ==================== JSON Helpers ====================

local function jsonEncode(val)
    if type(val) == "string" then
        return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
    elseif type(val) == "number" then
        return tostring(val)
    elseif type(val) == "boolean" then
        return val and "true" or "false"
    elseif type(val) == "nil" then
        return "null"
    elseif type(val) == "table" then
        local isArray = true
        local maxN = 0
        for k, _ in pairs(val) do
            if type(k) == "number" then
                if k > maxN then maxN = k end
            else
                isArray = false
                break
            end
        end
        if isArray and maxN > 0 then
            local parts = {}
            for i = 1, maxN do
                table.insert(parts, jsonEncode(val[i]))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        elseif isArray and maxN == 0 then
            local hasKeys = false
            for _ in pairs(val) do hasKeys = true; break end
            if not hasKeys then return "[]" end
        end
        local parts = {}
        for k, v in pairs(val) do
            table.insert(parts, jsonEncode(tostring(k)) .. ":" .. jsonEncode(v))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

local function jsonDecode(str)
    if not str or str == "" then return nil end
    str = str:match("^%s*(.-)%s*$")

    if str == "null" then return nil end
    if str == "true" then return true end
    if str == "false" then return false end
    if str:match("^%-?%d+%.?%d*$") then return tonumber(str) end
    if str:sub(1,1) == '"' and str:sub(-1) == '"' then
        return str:sub(2, -2):gsub('\\"', '"'):gsub('\\n', '\n'):gsub('\\\\', '\\')
    end

    if str:sub(1,1) == "{" then
        local item = {}
        for key, val in str:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do
            item[key] = val
        end
        for key, val in str:gmatch('"([^"]+)"%s*:%s*(%d+)') do
            item[key] = tonumber(val)
        end
        for key, val in str:gmatch('"([^"]+)"%s*:%s*(true)') do
            item[key] = true
        end
        for key, val in str:gmatch('"([^"]+)"%s*:%s*(false)') do
            item[key] = false
        end
        if next(item) then return item end
        return nil
    end

    if str:sub(1,1) == "[" then
        local result = {}
        for obj in str:gmatch("%b{}") do
            local item = {}
            for key, val in obj:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do
                item[key] = val
            end
            for key, val in obj:gmatch('"([^"]+)"%s*:%s*(%d+)') do
                item[key] = tonumber(val)
            end
            if next(item) then
                table.insert(result, item)
            end
        end
        return result
    end

    return nil
end

-- ==================== HTTP Helpers ====================

local function panelPost(endpoint, data, callback)
    local url = PANEL_HOST .. endpoint
    local jsonData = jsonEncode(data or {})

    HTTP.RequestAsync(url, "post", jsonData, "application/json", {
        ["X-Panel-Secret"] = PANEL_SECRET
    }, function(status, responseData)
        if status ~= 200 then
            Console.Log("[Panel] POST " .. endpoint .. " failed: status=" .. tostring(status))
        end
        if callback then
            callback(status, responseData)
        end
    end)
end

local function panelGet(endpoint, callback)
    local url = PANEL_HOST .. endpoint

    HTTP.RequestAsync(url, "get", "", "application/json", {
        ["X-Panel-Secret"] = PANEL_SECRET
    }, function(status, responseData)
        if callback then
            callback(status, responseData)
        end
    end)
end

-- ==================== Player Data Collection ====================

local function getPlayerData(serverID)
    local data = {
        serverId = serverID,
        name = Player.GetName(serverID) or "Unknown",
        ping = 0,
        ip = "",
        session = 0,
        sessionActive = false
    }

    local ok, val

    ok, val = pcall(Player.GetPing, serverID)
    if ok then data.ping = val or 0 end

    ok, val = pcall(Player.GetIP, serverID)
    if ok then data.ip = val or "" end

    ok, val = pcall(Player.GetSession, serverID)
    if ok then data.session = val or 0 end

    ok, val = pcall(Player.IsSessionActive, serverID)
    if ok then data.sessionActive = val or false end

    local tracked = connectedPlayers[serverID]
    if tracked then
        data.joinTime = tracked.joinTime or 0
    end

    return data
end

local function getAllPlayers()
    local players = {}
    for serverID, _ in pairs(connectedPlayers) do
        local ok, connected = pcall(Player.IsConnected, serverID)
        if ok and connected then
            table.insert(players, getPlayerData(serverID))
        end
    end
    return players
end

-- ==================== Send Full Player Sync ====================

local function syncPlayers()
    local players = getAllPlayers()
    panelPost("/api/panel-hook/players-sync", {
        players = players,
        playerCount = #players,
        resource = Resource.GetCurrentName()
    })
end

-- ==================== Action Processing ====================
-- Called from heartbeat thread context - Thread.Pause is safe here

local function processActions()
    while #actionQueue > 0 do
        local action = table.remove(actionQueue, 1)

        if action.type == "kick" then
            local sid = tonumber(action.serverId)
            if sid then
                local ok, connected = pcall(Player.IsConnected, sid)
                if ok and connected then
                    local name = Player.GetName(sid) or "Unknown"
                    local reason = action.reason or "Kicked by admin"
                    Console.Log("[Panel] Kicking: " .. name .. " (ID: " .. sid .. ") - " .. reason)

                    -- Send message before kick, then wait so it arrives
                    pcall(Chat.SendMessage, sid, "{FF0000}You have been kicked: " .. reason)
                    Thread.Pause(800)
                    pcall(Player.Kick, sid, reason)
                end
            end

        elseif action.type == "message" then
            local sid = tonumber(action.serverId)
            local msg = action.message or ""
            local duration = tonumber(action.duration) or 5
            if duration < 2 then duration = 2 end
            if duration > 20 then duration = 20 end
            if sid and msg ~= "" then
                if SEND_CHAT_MESSAGES then
                    pcall(Chat.SendMessage, sid, "{C0C0FF}[Panel] {FFFFFF}" .. msg)
                end

                -- Also notify via client event for WebUI overlay
                pcall(Events.CallRemote, "panel:notification", sid, { sid, msg, "message", duration })
            end

        elseif action.type == "broadcast" then
            local msg = action.message or ""
            local duration = tonumber(action.duration) or 5
            if duration < 2 then duration = 2 end
            if duration > 20 then duration = 20 end
            if msg ~= "" then
                if SEND_CHAT_MESSAGES then
                    pcall(Chat.BroadcastMessage, "{FFC800}[Broadcast] {FFFFFF}" .. msg)
                end

                -- Notify via client event for WebUI overlay
                pcall(Events.BroadcastRemote, "panel:notification", { 0, msg, "broadcast", duration })
            end

        elseif action.type == "set_session" then
            local sid = tonumber(action.serverId)
            local sessionId = tonumber(action.sessionId)
            if sid and sessionId then
                pcall(Player.SetSession, sid, sessionId)
            end
        end
    end
end

-- ==================== In-Game Admin Actions ====================
-- Called from client WebUI (/admin or /tx)

Events.Subscribe("panel:adminAction", function(action, a, b, c)
    if not action then return end
    if type(action) == "table" then
        local t = action
        action = t[1]
        a = t[2]
        b = t[3]
        c = t[4]
        if not action then return end
    end
    local source = Events.GetSource()

    if action == "broadcast" then
        local msg = a or ""
        local duration = tonumber(b) or 5
        if duration < 2 then duration = 2 end
        if duration > 20 then duration = 20 end
        if msg ~= "" then
            -- Broadcast notification only (no chat spam)
            pcall(Events.BroadcastRemote, "panel:notification", { 0, msg, "broadcast", duration })
        end
        return
    end

    if action == "message" then
        local sid = tonumber(a)
        local msg = b or ""
        local duration = tonumber(c) or 5
        if duration < 2 then duration = 2 end
        if duration > 20 then duration = 20 end
        if sid and msg ~= "" then
            pcall(Events.CallRemote, "panel:notification", sid, { sid, msg, "message", duration })
        end
        return
    end

    if action == "set_session" then
        local sessionId = tonumber(a)
        if sessionId then
            pcall(Player.SetSession, source, sessionId)
        end
        return
    end
end, true)

-- ==================== Poll for Pending Actions ====================
-- HTTP callback stores actions in queue instead of processing inline
-- This avoids "CreateThread can not be used inside of a thread" error

local function pollActions()
    panelGet("/api/panel-hook/pending-actions?secret=" .. PANEL_SECRET, function(status, data)
        if status ~= 200 or not data then return end

        local actions = jsonDecode(data)
        if not actions or type(actions) ~= "table" then return end

        for _, action in ipairs(actions) do
            table.insert(actionQueue, action)
        end
    end)
end

-- ==================== Player Events ====================

Events.Subscribe("playerJoin", function()
    local source = Events.GetSource()
    local name = Player.GetName(source) or "Unknown"

    -- Track player
    connectedPlayers[source] = {
        name = name,
        joinTime = os.time()
    }

    -- Get full data and send to panel
    local playerData = getPlayerData(source)

    panelPost("/api/panel-hook/player-join", playerData, function(status, responseData)
        -- If panel says player is banned, queue a kick
        -- (processed by heartbeat thread where Thread.Pause is safe)
        if status == 200 and responseData then
            local result = jsonDecode(responseData)
            if result and result.banned then
                Console.Log("[Panel] Player " .. name .. " is banned - queuing kick")
                table.insert(actionQueue, {
                    type = "kick",
                    serverId = source,
                    reason = "Banned from this server"
                })
            end
        end
    end)

    Console.Log("[Panel] Player joined: " .. name .. " (ID: " .. source .. ")")
end, true)

Events.Subscribe("playerDisconnect", function(id, name, reason)
    connectedPlayers[id] = nil

    local reasonStr = "unknown"
    if reason == 0 then reasonStr = "timeout"
    elseif reason == 1 then reasonStr = "quit"
    elseif reason == 2 then reasonStr = "kick"
    end

    panelPost("/api/panel-hook/player-disconnect", {
        serverId = id,
        name = name or "Unknown",
        reason = reasonStr
    })
end)

-- ==================== Resource Events ====================

Events.Subscribe("resourceStart", function(resourceName)
    panelPost("/api/panel-hook/resource-state", {
        resource = resourceName,
        state = "started"
    })
end)

Events.Subscribe("resourceStop", function(resourceName)
    panelPost("/api/panel-hook/resource-state", {
        resource = resourceName,
        state = "stopped"
    })
end)

-- ==================== Heartbeat & Polling Loop ====================

Events.Subscribe("resourceStart", function(resName)
    if resName == Resource.GetCurrentName() then
        Console.Log("[HMP Connector] Started - connecting to panel at " .. PANEL_HOST)

        Thread.Create(function()
            while true do
                syncPlayers()

                pollActions()

                Thread.Pause(2000)

                processActions()

                Thread.Pause(3000)
            end
        end)
    end
end)

Console.Log("[HMP Connector] Resource loaded - waiting for start...")
