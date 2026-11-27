--[[
require("modules.dev_tools").start({
    -- width = 500, -- 可选：浮窗宽度；默认位于主屏幕右下角，贴屏幕底边
    -- margin = 4, -- 可选：距屏幕右侧的距离
})
-- 点击两行信息分别复制应用 Bundle ID / 输入法 ID；左侧按钮清空日志、重载配置。
-- 鼠标左键拖动浮窗可自由移动。显示当前前台应用及实际输入法；不抢焦点，切换桌面和全屏时保持显示。
]]
local M = {}
local panel, appWatcher, screenWatcher, refreshTimer, dragTap
local draggedPosition, dragOrigin, dragFrame, pressedAction, moved
local appBundleID, inputSourceID
local width, margin
local height = 40
local function position()
    if not panel then return end
    if draggedPosition then
        panel:frame({ x = draggedPosition.x, y = draggedPosition.y, w = width, h = height })
        return
    end
    local screen = hs.screen.primaryScreen()
    if not screen then return end
    local frame = screen:fullFrame()
    panel:frame({ x = frame.x + frame.w - width - margin, y = frame.y + frame.h - height,
        w = width, h = height })
end
local function stopDrag()
    if dragTap then dragTap:stop(); dragTap = nil end
    dragOrigin, dragFrame, pressedAction, moved = nil, nil, nil, nil
end
local function actionAt(pointer, frame)
    local x, y = pointer.x - frame.x, pointer.y - frame.y
    if x < 0 or x >= frame.w or y < 0 or y >= frame.h then return nil end
    if x < 78 then return y < height / 2 and "clear" or "reload" end
    return y < height / 2 and "copyApp" or "copySource"
end
local function performAction(action)
    if action == "clear" then hs.console.clearConsole()
    elseif action == "reload" then hs.reload()
    else
        local value = action == "copyApp" and appBundleID or (action == "copySource" and inputSourceID)
        if value then
            if hs.pasteboard.setContents(value) then
                hs.alert.show("已复制：" .. value, 1)
            else
                hs.alert.show("复制失败", 1)
            end
        end
    end
end
local function watchDragging()
    local types = hs.eventtap.event.types
    dragTap = hs.eventtap.new({ types.leftMouseDown, types.leftMouseDragged, types.leftMouseUp }, function(event)
        if not panel then return false end
        local kind, pointer = event:getType(), event:location()
        if kind == types.leftMouseDown then
            local frame = panel:frame()
            if pointer.x < frame.x or pointer.x >= frame.x + frame.w
                or pointer.y < frame.y or pointer.y >= frame.y + frame.h then return false end
            dragOrigin, dragFrame = pointer, frame
            pressedAction, moved = actionAt(pointer, frame), false
            return true
        end
        if not dragOrigin then return false end
        local dx, dy = pointer.x - dragOrigin.x, pointer.y - dragOrigin.y
        moved = moved or dx * dx + dy * dy > 16
        if moved then
            draggedPosition = { x = dragFrame.x + dx, y = dragFrame.y + dy }
            position()
        end
        if kind == types.leftMouseUp then
            local action = not moved and actionAt(pointer, dragFrame) == pressedAction and pressedAction
            dragOrigin, dragFrame, pressedAction, moved = nil, nil, nil, nil
            if action then performAction(action) end
        end
        return true
    end):start()
end
local function refresh()
    if not panel then return end
    local app = hs.application.frontmostApplication()
    appBundleID = app and app:bundleID()
    inputSourceID = hs.keycodes.currentSourceID()
    local source = inputSourceID or "未知"
    local method = hs.keycodes.currentMethod() or hs.keycodes.currentLayout() or "未知"
    panel[2].text = (app and app:name() or "未知") .. ": " .. (appBundleID or "无 Bundle ID")
    panel[3].text = method .. ": " .. source
end
local function scheduleRefresh()
    -- 等同一轮应用切换事件中的输入法规则执行完，再读取实际状态。
    if refreshTimer then refreshTimer:stop() end
    refreshTimer = hs.timer.doAfter(0, function()
        refreshTimer = nil
        refresh()
    end)
end
function M.stop()
    stopDrag()
    if appWatcher then appWatcher:stop(); appWatcher = nil end
    if screenWatcher then screenWatcher:stop(); screenWatcher = nil end
    if refreshTimer then refreshTimer:stop(); refreshTimer = nil end
    if panel then
        hs.keycodes.inputSourceChanged(nil)
        panel:delete(); panel = nil
    end
    return M
end
function M.start(options)
    M.stop()
    options = options or {}
    width, margin = options.width or 500, options.margin or 4
    assert(type(width) == "number" and width >= 240, "width 必须大于等于 240")
    assert(type(margin) == "number" and margin >= 0, "margin 必须大于等于 0")
    panel = hs.canvas.new({ x = 0, y = 0, w = width, h = height })
    panel:level("overlay"):behavior({ "canJoinAllSpaces", "fullScreenAuxiliary", "stationary" })
    panel:appendElements({ type = "rectangle", action = "fill", fillColor = { white = 0.08, alpha = 0.88 },
        roundedRectRadii = { xRadius = 4, yRadius = 4 } })
    for index = 1, 2 do
        panel:appendElements({ type = "text", text = "", textSize = 11,
            textColor = { white = index == 2 and 0.75 or 1 }, textFont = "Menlo",
            frame = { x = 84, y = 3 + (index - 1) * 17, w = width - 90, h = 16 } })
    end
    panel:appendElements({ type = "rectangle", action = "fill", fillColor = { white = 1, alpha = 0.06 },
        frame = { x = 0, y = 0, w = 78, h = height } })
    for index, title in ipairs({ "清空日志", "重载配置" }) do
        panel:appendElements({ type = "text", text = title, textSize = 11,
            textColor = { white = 0.85 }, textAlignment = "center",
            frame = { x = 0, y = 3 + (index - 1) * 20, w = 78, h = 16 } })
    end
    appWatcher = hs.application.watcher.new(function(_, event)
        if event == hs.application.watcher.activated then scheduleRefresh() end
    end):start()
    -- Hammerspoon 的输入法变化回调为单一槽位，由本模块统一用于状态显示。
    hs.keycodes.inputSourceChanged(scheduleRefresh)
    screenWatcher = hs.screen.watcher.new(position):start()
    position()
    refresh()
    panel:show()
    watchDragging()
    return M
end
return M
