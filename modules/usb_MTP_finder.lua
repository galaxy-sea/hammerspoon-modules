-- https://github.com/ClassicOldSong/MacMTP
-- https://github.com/skuthus/Moorage  不好用 大文件经常传输失败

--[[
require("modules.usb_MTP_finder").start({
    appBundleID = "com.sudomaker.MacMTP", -- 必填：用户指定要启动和退出的软件
    -- appName = "MacMTP", -- 可选：日志显示名称，省略时使用 Bundle ID
    disconnectDelay = 1,
    queryTimeout = 10,
})
]]
-- 启动时及 USB 插拔后各查询一次 USB 接口；无常驻监听进程、无自动重查。
local M = {}
local defaults = {
    disconnectDelay = 1,
    queryTimeout = 10,
}
local cfg, usbWatcher, appWatcher, queryTask, timeoutTimer, actionTimer
local previousShutdown, shutdownHook
local running, available, devices, lastError = false, nil, {}, nil
local revision, checkPending = 0, false
local quitRequested = {} -- PID -> 应用实例；一直保留到进程完全退出。
local restartPending = false
local log = hs.logger.new("usb_MTP_finder", "info")
local query, requestCheck

local function stopTimer(timer) if timer then timer:stop() end end
local function short(text) return tostring(text or ""):sub(1, 2000) end
local function queryFailed(reason)
    available, devices, lastError = nil, {}, reason
    stopTimer(actionTimer); actionTimer = nil
    log.e(short(reason)) -- 查询失败不等于没有设备，不据此关闭应用。
end
local function safe(fn)
    return function(...)
        local ok, result = xpcall(fn, debug.traceback, ...)
        if not ok then queryFailed("回调错误：" .. short(result)); return end
        return result
    end
end

local function stopTask()
    local task = queryTask
    queryTask = nil
    if task then
        task:setCallback(nil)
        if task:isRunning() then task:terminate() end
    end
end

local function reconcile()
    if not running or available == nil then return end
    local apps = {}
    for _, app in ipairs(hs.application.applicationsForBundleID(cfg.appBundleID) or {}) do
        if app:isRunning() then apps[#apps + 1] = app end
    end
    if available then
        local exiting = false
        for pid, app in pairs(quitRequested) do
            if app:isRunning() then exiting = true
            else quitRequested[pid] = nil end
        end
        if exiting then
            if not restartPending then log.d(cfg.appName .. " 正在退出，等待进程完全结束后再启动") end
            restartPending = true
            return
        end
        restartPending = false
        if #apps == 0 then
            log.i("检测到 MTP 接口，启动 " .. cfg.appName)
            if not hs.application.launchOrFocusByBundleID(cfg.appBundleID) then
                log.e("无法启动应用：" .. cfg.appBundleID .. "；等待下一次检查")
            end
        end
    else
        restartPending = false
        for _, app in ipairs(apps) do
            local pid = app:pid()
            if pid and not quitRequested[pid] then
                quitRequested[pid] = app
                log.i("请求 " .. cfg.appName .. " 正常退出，等待应用自行清理；PID=" .. pid)
                app:kill()
            end
        end
    end
end

local function snapshot(output)
    local interfaces = hs.plist.readString(output)
    assert(type(interfaces) == "table", "ioreg 未返回有效 USB 接口列表")
    local nextDevices, seen = {}, {}
    for _, interface in ipairs(interfaces) do
        -- 仅接口明确声明 MTP 时命中；不把同为 6/1/1 的 PTP 相机误判为 MTP。
        local name = interface["USB Interface Name"] or interface.kUSBString or interface.IORegistryEntryName or ""
        if tostring(name):upper():find("MTP", 1, true) then
            local id = tostring(interface.locationID or interface.IORegistryEntryID or "")
            if id ~= "" and not seen[id] then
                seen[id] = true
                nextDevices[#nextDevices + 1] = id
            end
        end
    end
    table.sort(nextDevices)
    local changed = available == nil or table.concat(nextDevices, "\n") ~= table.concat(devices, "\n")
    devices, available, lastError = nextDevices, #nextDevices > 0, nil
    if changed then
        log.d("MTP USB 设备：" .. #devices .. (#devices > 0 and ("；" .. table.concat(devices, ", ")) or ""))
    end
    stopTimer(actionTimer)
    local currentRevision = revision
    actionTimer = hs.timer.doAfter(available and 0 or cfg.disconnectDelay, safe(function()
        actionTimer = nil
        if revision == currentRevision then reconcile() end
    end))
end

query = function()
    if not running or queryTask or not checkPending then return end
    checkPending = false
    local currentRevision = revision
    local task
    task = hs.task.new("/usr/sbin/ioreg", safe(function(code, stdout, stderr)
        if not running or queryTask ~= task then return end
        queryTask = nil
        stopTimer(timeoutTimer); timeoutTimer = nil
        -- 插拔期间结束的旧查询不控制应用，新一轮查询会在它退出后启动。
        if revision == currentRevision then
            if code == 0 then
                local ok, err = pcall(snapshot, stdout)
                if not ok then queryFailed("解析 USB 接口列表失败：" .. short(err)) end
            else
                queryFailed("USB 接口查询失败，exit=" .. tostring(code) .. "；" .. short(stderr))
            end
        end
        if checkPending then query() end
    end), { "-a", "-r", "-c", "IOUSBHostInterface", "-d", "1" })
    queryTask = task
    if not task or not task:start() then
        queryTask = nil
        queryFailed("无法启动 ioreg")
        if checkPending then query() end
        return
    end
    timeoutTimer = hs.timer.doAfter(cfg.queryTimeout, safe(function()
        if queryTask ~= task then return end
        timeoutTimer = nil
        stopTask()
        if revision == currentRevision then queryFailed("USB 接口查询超时") end
        if checkPending then query() end
    end))
end

requestCheck = function(reason)
    if not running then return end
    revision = revision + 1
    available = nil -- 不使用 USB 变化前的设备状态启动或关闭应用。
    checkPending = true
    stopTimer(actionTimer); actionTimer = nil
    log.d(reason)
    -- 有查询在运行时合并新事件，等旧查询退出后立即查询最新状态，不并发查询。
    query()
end

function M.start(options)
    if running then return M end
    cfg = {}
    for key, value in pairs(defaults) do cfg[key] = value end
    for key, value in pairs(options or {}) do
        assert(defaults[key] ~= nil or key == "appBundleID" or key == "appName", "未知配置：" .. tostring(key))
        cfg[key] = value
    end
    cfg.appName = cfg.appName or cfg.appBundleID
    for _, key in ipairs({ "appBundleID", "appName" }) do
        assert(type(cfg[key]) == "string" and cfg[key] ~= "", key .. " 不能为空")
    end
    assert(type(cfg.queryTimeout) == "number" and cfg.queryTimeout > 0, "queryTimeout 必须 > 0")
    assert(type(cfg.disconnectDelay) == "number" and cfg.disconnectDelay >= 0, "disconnectDelay 必须 >= 0")
    running, available, devices, lastError = true, nil, {}, nil
    quitRequested, checkPending, restartPending = {}, false, false
    usbWatcher = hs.usb.watcher.new(safe(function(event)
        if event.eventType ~= "added" and event.eventType ~= "removed" then return end
        requestCheck("USB " .. event.eventType .. "：" .. short(event.productName or event.vendorName))
    end)):start()
    -- terminated 通知中的名称可能为 nil，应用对象也只能可靠地读取 PID。
    appWatcher = hs.application.watcher.new(safe(function(_, event, app)
        if not running or event ~= hs.application.watcher.terminated then return end
        local pid = app and app:pid()
        if not pid or not quitRequested[pid] then return end
        quitRequested[pid] = nil
        log.d(cfg.appName .. " 进程已完全退出；PID=" .. pid)
        if restartPending and next(quitRequested) == nil and available == true then
            reconcile() -- 使用最近一次已确认的设备状态，不增加 USB 查询或启动重试。
        end
    end)):start()
    local previousCallback = hs.shutdownCallback
    previousShutdown = previousCallback
    shutdownHook = function()
        M.stop()
        if previousCallback then previousCallback() end
    end
    hs.shutdownCallback = shutdownHook
    requestCheck("模块启动；监听 USB 插拔，检查当前设备")
    return M
end

function M.stop()
    if not running then return end
    running, available, devices = false, nil, {}
    revision = revision + 1
    checkPending, restartPending = false, false
    stopTimer(timeoutTimer); stopTimer(actionTimer)
    timeoutTimer, actionTimer = nil, nil
    if usbWatcher then usbWatcher:stop(); usbWatcher = nil end
    if appWatcher then appWatcher:stop(); appWatcher = nil end
    stopTask()
    if hs.shutdownCallback == shutdownHook then hs.shutdownCallback = previousShutdown end
    log.d("模块已停止")
end

-- 如需主动刷新设备状态，可从控制台手动调用一次。
function M.check()
    requestCheck("手动检查设备")
    return M
end

function M.status()
    local copy = {}
    for index, serial in ipairs(devices) do copy[index] = serial end
    local exiting = {}
    for pid in pairs(quitRequested) do exiting[#exiting + 1] = pid end
    table.sort(exiting)
    return { running = running, watchingUSB = usbWatcher ~= nil, checking = queryTask ~= nil,
        checkPending = checkPending, exitingPIDs = exiting, restartPending = restartPending,
        available = available, devices = copy, lastError = lastError }
end

return M
