-- Turn off Wi-Fi once, after the last online window closes in the reader.
local Device = require("device")
local NetworkMgr = require("ui/network/manager")

if not Device:hasWifiToggle() or not NetworkMgr:getNetworkInterfaceName() then return end

local NetworkListener = require("ui/network/networklistener")
local UIManager = require("ui/uimanager")
local datetime = require("datetime")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")

local enabled_key = "auto_disable_wifi"
local delay_key = "reader_wifi_idle_timeout_seconds"
local delays = { 30, 60, 90, 120 }
local default_delay = 60
local suspended, turning_off = false, false
local online_windows = setmetatable({}, { __mode = "k" })
local closing_readers = setmetatable({}, { __mode = "k" })
local timer_reader, closed_at
local online_plugins = {
    koassistant = true, localsend = true, newsdownloader = true, opds = true,
    opds_plus = true, storefront = true, wallabag = true,
}
local widget_callbacks = {
    "close_callback", "dismiss_callback", "onCloseWidget", "onLeftButtonTap",
    "onMenuSelect", "onReturn", "onShow",
}
local translation_prefix, translation_suffix = _("Translation from %1"):match("^(.-)%%1(.*)$")
local querying_translation = _("Querying translation service…")

local function getDelay()
    local saved_delay = G_reader_settings:readSetting(delay_key)
    for _, delay in ipairs(delays) do
        if saved_delay == delay then return delay end
    end
    return default_delay
end

-- Inspect the identity of existing windows without calling widget handlers or
-- loading plugin modules. Use raw reads so custom fields cannot invoke code.
local function isOnlineSource(source, callback)
    if source:match("[@/]ui/translator%.lua$") or source:match("[@/]readerwikipedia%.lua$") then return true end
    local plugin = source:match("[@/]([^/]+)%.koplugin/")
    if not plugin then return false end
    if online_plugins[plugin] then return true end

    -- A plugin may expose one of KOReader's network actions on its window.
    for index = 1, 12 do
        local name, value = debug.getupvalue(callback, index)
        if not name then break end
        if rawequal(value, NetworkMgr) then return true end
    end
    return false
end

local function isOnlineCallback(callback)
    return type(callback) == "function" and isOnlineSource(debug.getinfo(callback, "S").source, callback)
end

local function shownByOnlinePlugin()
    for level = 3, 14 do
        local caller = debug.getinfo(level, "Sf")
        if not caller then break end
        if isOnlineSource(caller.source, caller.func) then return true end
    end
    return false
end

local function hasOnlineCallbacks(widget)
    local prototype = widget
    for _ = 1, 8 do
        if type(prototype) ~= "table" then break end
        for _, key in ipairs(widget_callbacks) do
            if isOnlineCallback(rawget(prototype, key)) then return true end
        end
        prototype = getmetatable(prototype)
    end

    local buttons = rawget(widget, "buttons")
    if type(buttons) == "table" then
        for row = 1, 4 do
            local entries = rawget(buttons, row)
            if type(entries) ~= "table" then break end
            for column = 1, 4 do
                local button = rawget(entries, column)
                if type(button) == "table" and isOnlineCallback(rawget(button, "callback")) then
                    return true
                end
            end
        end
    end
    return false
end

local function isOnlineWindow(widget)
    if rawget(widget, "reader_wifi_keep_on") or rawget(widget, "is_wiki") then return true end
    if rawget(widget, "text") == querying_translation then return true end

    local title = rawget(widget, "title")
    if rawget(widget, "text_type") == "lookup" and type(title) == "string" and translation_prefix
        and title:sub(1, #translation_prefix) == translation_prefix
        and title:sub(#title - #translation_suffix + 1) == translation_suffix then
        return true
    end

    return hasOnlineCallbacks(widget)
end

local function isWindow(widget, reader)
    if type(widget) ~= "table" or widget == reader or widget == reader.dialog then return false end
    local prototype = widget
    for _ = 1, 8 do
        if type(prototype) ~= "table" then break end
        if rawget(prototype, "invisible") or rawget(prototype, "toast") then return false end
        prototype = getmetatable(prototype)
    end
    return true
end

local function hasOnlineWindow(ui, reader)
    for widget in ui:topdown_widgets_iter() do
        if isWindow(widget, reader) and (online_windows[widget] or isOnlineWindow(widget)) then return true end
    end
    return false
end

local function getReader()
    if suspended or turning_off then return end
    local class = package.loaded["apps/reader/readerui"]
    local reader = class and class.instance
    if reader and reader.document and not closing_readers[reader] and G_reader_settings:isTrue(enabled_key) then
        return reader
    end
end

local onTimeout
local function cancelTimer()
    if timer_reader then
        UIManager:unschedule(onTimeout)
        timer_reader, closed_at = nil, nil
    end
end

local function observe(action, ...)
    local ok, result = pcall(action, ...)
    if not ok then
        cancelTimer()
        logger.warn("Reader Wi-Fi idle timer:", result)
        return
    end
    return result
end

local function turnOffIfIdle(reader)
    if reader == getReader() and not hasOnlineWindow(UIManager, reader) and NetworkMgr:isWifiOn() then
        turning_off = true
        observe(NetworkMgr.disableWifi, NetworkMgr)
        turning_off = false
    end
end

onTimeout = function()
    local reader = timer_reader
    timer_reader, closed_at = nil, nil
    if reader then observe(turnOffIfIdle, reader) end
end

local function scheduleTimeout()
    UIManager:unschedule(onTimeout)
    UIManager:schedule(closed_at + time.s(getDelay()), onTimeout)
end

local function onWindowShown(ui, widget)
    if ui:isWidgetShown(widget) and (shownByOnlinePlugin() or isOnlineWindow(widget)) then
        online_windows[widget] = true
        cancelTimer()
    end
end

local show = UIManager.show
function UIManager:show(widget, ...)
    local result = show(self, widget, ...)
    local reader = getReader()
    if reader and isWindow(widget, reader) then observe(onWindowShown, self, widget) end
    return result
end

local function isShownOnlineWindow(ui, widget)
    return ui:isWidgetShown(widget) and (online_windows[widget] or isOnlineWindow(widget))
end

local function onWindowClosed(ui, widget, reader)
    if ui:isWidgetShown(widget) then return end
    online_windows[widget] = nil
    if reader ~= getReader() or hasOnlineWindow(ui, reader) or not NetworkMgr:isWifiOn() then return end
    timer_reader, closed_at = reader, time.now()
    scheduleTimeout()
end

local close = UIManager.close
function UIManager:close(widget, ...)
    local reader = getReader()
    local was_online = reader and isWindow(widget, reader) and observe(isShownOnlineWindow, self, widget)
    local result = close(self, widget, ...)
    if was_online then observe(onWindowClosed, self, widget, reader) end
    return result
end

-- Leave the native Wi-Fi handlers in place and replace their periodic timer.
NetworkListener:_unscheduleActivityCheck()
NetworkListener._scheduleActivityCheck = function() end

function NetworkListener:onCloseDocument()
    if self.ui then closing_readers[self.ui] = true end
    cancelTimer()
    online_windows = setmetatable({}, { __mode = "k" })
end

function NetworkListener:onCloseWidget()
    if self.document then
        self:onCloseDocument()
    end
end

NetworkListener.onNetworkDisconnecting = cancelTimer

local onNetworkDisconnected = NetworkListener.onNetworkDisconnected
function NetworkListener:onNetworkDisconnected()
    cancelTimer()
    return onNetworkDisconnected(self)
end

local onSuspend = NetworkListener.onSuspend
function NetworkListener:onSuspend()
    suspended = true
    cancelTimer()
    return onSuspend(self)
end

local onResume = NetworkListener.onResume
function NetworkListener:onResume()
    suspended = false
    if onResume then return onResume(self) end
end

local function applySetting()
    if not getReader() then
        cancelTimer()
    elseif timer_reader then
        observe(scheduleTimeout)
    end
    G_reader_settings:flush()
end

local function toggleEnabled()
    G_reader_settings:flipNilOrFalse(enabled_key)
    applySetting()
end

local getPowersaveMenuTable = NetworkMgr.getPowersaveMenuTable
function NetworkMgr:getPowersaveMenuTable()
    local item = getPowersaveMenuTable(self)
    item.callback = nil
    item.checkmark_callback = toggleEnabled
    item.help_text = _.current_lang == "it_IT"
        and "Durante la lettura, spegne il Wi-Fi dopo il tempo scelto a partire dalla chiusura dell’ultima finestra di un servizio online."
        or _("While reading, turns off Wi-Fi after the selected delay when the last online service window is closed.")
    item.sub_item_table = {
        {
            text = _("Enable"),
            checked_func = item.checked_func,
            callback = toggleEnabled,
            separator = true,
        },
    }
    for _, delay in ipairs(delays) do
        table.insert(item.sub_item_table, {
            text = datetime.secondsToHClock(delay, delay % 60 == 0, true, false, true),
            radio = true,
            checked_func = function() return getDelay() == delay end,
            callback = function()
                G_reader_settings:saveSetting(delay_key, delay)
                applySetting()
            end,
        })
    end
    return item
end
