local notifUI = nil
local adminUI = nil
local adminVisible = false
local adminTick = nil

local function clamp(n, min, max)
    n = tonumber(n) or min
    if n < min then return min end
    if n > max then return max end
    return n
end

local function getLocalServerId()
    local ok, sid = pcall(function()
        return Player.GetServerID(Game.GetPlayerId())
    end)
    if ok then return sid end
    return nil
end

local function sendClientIdentifiers()
    local ids = {}
    local ok, rid = pcall(function()
        return Player.GetRockstarID(Game.GetPlayerId())
    end)
    if ok and rid then
        ids.rockstarId = tostring(rid)
    end

    if next(ids) ~= nil then
        pcall(Events.CallRemote, "panel:clientIdentifiers", ids)
    end
end

local function sendAdminStatus()
    if not adminUI then return end
    local sid = getLocalServerId()
    local ping = 0
    local session = 0
    if sid then
        local ok, val = pcall(Player.GetPing, sid)
        if ok then ping = val or 0 end
        ok, val = pcall(Player.GetSession, sid)
        if ok then session = val or 0 end
    end
    WebUI.CallEvent(adminUI, "updateStatus", { sid, ping, session })
end

local function startAdminTicker()
    if adminTick then return end
    adminTick = Thread.Create(function()
        while adminVisible do
            sendAdminStatus()
            Thread.Pause(1500)
        end
        adminTick = nil
    end)
end

local function setAdminVisible(show)
    if not adminUI then return end
    adminVisible = show and true or false
    WebUI.CallEvent(adminUI, "setVisible", { adminVisible })
    if adminVisible then
        WebUI.SetFocus(adminUI, false)
        sendAdminStatus()
        startAdminTicker()
    else
        WebUI.SetFocus(-1)
    end
end

Events.Subscribe("resourceStart", function(resName)
    if resName == Resource.GetCurrentName() then
        notifUI = WebUI.Create("file://hpm-connector/webui/notification.html", 1920, 1080, true)
        adminUI = WebUI.Create("file://hpm-connector/webui/admin.html", 1920, 1080, true)
        WebUI.CallEvent(adminUI, "setVisible", { false })

        Thread.Create(function()
            Thread.Pause(1500)
            sendClientIdentifiers()
        end)
    end
end)

Events.Subscribe("resourceStop", function(resName)
    if resName == Resource.GetCurrentName() then
        if notifUI then
            pcall(WebUI.Destroy, notifUI)
            notifUI = nil
        end
        if adminUI then
            pcall(WebUI.Destroy, adminUI)
            adminUI = nil
        end
    end
end)

Events.Subscribe("panel:notification", function(targetSid, message, msgType, duration)
    if not notifUI then return end
    if type(targetSid) == "table" then
        local t = targetSid
        targetSid = t[1]
        message = t[2]
        msgType = t[3]
        duration = t[4]
    end
    if not message or message == "" then return end

    msgType = msgType or "message"
    duration = clamp(duration or 5, 2, 20)

    if msgType == "broadcast" or targetSid == 0 then
        WebUI.CallEvent(notifUI, "showNotification", { message, msgType, duration })
    else
        local myServerID = getLocalServerId()
        if myServerID and myServerID == targetSid then
            WebUI.CallEvent(notifUI, "showNotification", { message, msgType, duration })
        end
    end
end, true)

Events.Subscribe("chatCommand", function(command)
    if command == "/admin" then
        setAdminVisible(not adminVisible)
    end
end)

Events.Subscribe("panel:adminToggle", function()
    setAdminVisible(not adminVisible)
end)

Events.Subscribe("panel:adminAction", function(action, a, b, c)
    if type(action) == "table" then
        local t = action
        action = t[1]
        a = t[2]
        b = t[3]
        c = t[4]
    end
    if not action then return end

    if action == "heal" then
        pcall(function()
            local ped = Game.GetPlayerChar(Game.GetPlayerId())
            Game.SetCharHealth(ped, 200)
        end)
        return
    end

    if action == "armor" then
        pcall(function()
            local ped = Game.GetPlayerChar(Game.GetPlayerId())
            local ok = pcall(function() Game.SetCharArmour(ped, 100) end)
            if not ok then
                pcall(function() Game.AddArmourToChar(ped, 100) end)
            end
        end)
        return
    end

    if action == "set_session" then
        local targetSession = tonumber(a) or 0
        if targetSession == 999 then
            local sid = getLocalServerId()
            if sid then targetSession = sid end
        end
        pcall(Events.CallRemote, "panel:adminAction", "set_session", targetSession)
        return
    end

    if action == "broadcast" then
        local msg = a or ""
        local duration = clamp(b or 5, 2, 20)
        if msg ~= "" then
            pcall(Events.CallRemote, "panel:adminAction", "broadcast", msg, duration)
        end
        return
    end

    if action == "message" then
        local msg = a or ""
        local duration = clamp(b or 5, 2, 20)
        local sid = tonumber(c)
        if sid and msg ~= "" then
            pcall(Events.CallRemote, "panel:adminAction", "message", sid, msg, duration)
        end
        return
    end
end)
