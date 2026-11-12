--[[
require("modules.blink_reminder").start({
    intervalMinutes = 20,       -- 每轮提醒间隔（分钟），完成关闭流程后重新计时
    snoozeMinutes = { 1, 5, 10 }, -- 延后选项（分钟）；{} 不显示延后按钮
    hoverSeconds = 10,          -- 每次必须连续悬停的秒数，移出按钮重新计时
    hoverCount = 3,             -- 关闭共需悬停并点击的次数，含「已休息」这一次
    hotkey = { mods = { "ctrl", "alt", "cmd" }, key = "B", bind = false },
})
-- hotkey.bind = false 或省略 hotkey 时只启动定时提醒；.show() 可手动显示。
-- 所有悬浮按钮随机位置；确认按钮随机颜色，延后按钮仅显示文字，可直接点击。
]]

local M = {}

local PANEL_WIDTH, PANEL_HEIGHT = 500, 338
local BUTTON_WIDTH, BUTTON_HEIGHT = 112, 42  -- 更小的悬浮按钮；主体约 108 × 38 px
local EDGE_MARGIN = 14             -- 不遮住菜单栏、Dock，也不贴着边缘
local PANEL_CLEARANCE = 22         -- 随机按钮避开中央提醒窗口
local RANDOM_TRIES = 200

-- 每次独立随机生成 24 位 RGB 背景色（约 1677 万种），不再使用固定色板。
-- 按 WCAG 对比度逻辑自动选择黑字/白字，尽量保证按钮文字可读。
local function linearChannel(channel)
    local value = channel / 255
    if value <= 0.04045 then return value / 12.92 end
    return ((value + 0.055) / 1.055) ^ 2.4
end

local app = {
    running = false,
    intervalMinutes = 20,
    snoozeMinutes = { 1, 5, 10 },
    hoverSeconds = 10,
    hoverCount = 3,
    reminderTimer = nil,
    hoverTimer = nil,               -- 系统级鼠标位置轮询，不依赖 WebView 的 mouseenter
    stage = 0,                     -- 已完成的悬停确认次数；0 为初始提醒
    view = nil,                    -- 中央提醒窗口（含返回按钮）
    buttonView = nil,              -- 独立悬浮的随机确认按钮
    snoozeViews = {},              -- 独立随机位置/颜色的延后按钮
    bridge = nil,
    hotkey = nil,
    activeScreen = nil,
    lastButtonRect = nil,
    lastButtonColor = nil,
    buttonSession = 0,             -- 标记按钮实例，忽略旧窗口延迟发来的消息
    hoverStartedNs = nil,          -- 悬停开始时间（开机后的纳秒数）
    hoverStage = nil,
    buttonRect = nil,              -- 当前确认按钮的屏幕坐标
    lastHoverDisplay = nil,        -- 仅变化时更新按钮倒计时，减少 WebView 负担
}

local function stopTimer()
    if app.reminderTimer then
        app.reminderTimer:stop()
        app.reminderTimer = nil
    end
end

-- 支持从旧版模块/原始脚本迁移，清理旧定时器、窗口与菜单栏元素。
local function cleanupPreviousVersion()
    local old = rawget(_G, "blinkReminderApp")
    if not old or old == app then return end
    if old.reminderTimer then old.reminderTimer:stop() end
    if old.hoverTimer then old.hoverTimer:stop() end
    if old.countdownTimer then old.countdownTimer:stop() end
    if old.hotkey then old.hotkey:delete() end
    if old.menu then old.menu:delete() end
    if old.view then old.view:delete() end
    if old.buttonView then old.buttonView:delete() end
    for _, view in ipairs(old.snoozeViews or {}) do view:delete() end
    if old.bridge then old.bridge:setCallback(nil) end
    _G.blinkReminderApp = nil
end

local function panelFrame()
    local f = (app.activeScreen or hs.screen.mainScreen()):frame()
    local w = math.max(100, math.min(PANEL_WIDTH, f.w - EDGE_MARGIN * 2))
    local h = math.max(100, math.min(PANEL_HEIGHT, f.h - EDGE_MARGIN * 2))
    return {
        x = f.x + (f.w - w) / 2,
        y = f.y + (f.h - h) / 2,
        w = w,
        h = h,
    }
end

local function overlapsWithMargin(a, b, margin)
    return a.x < b.x + b.w + margin
       and a.x + a.w > b.x - margin
       and a.y < b.y + b.h + margin
       and a.y + a.h > b.y - margin
end

local function centerDistance(a, b)
    local dx = (a.x + a.w / 2) - (b.x + b.w / 2)
    local dy = (a.y + a.h / 2) - (b.y + b.h / 2)
    return math.sqrt(dx * dx + dy * dy)
end

-- 随机坐标覆盖当前显示器的可用区域（扣除菜单栏和Dock），不局限九宫格。
-- 还会尽量远离上一次按钮的位置，防止在固定位置连续点击。
local function randomButtonFrame(occupied)
    local f = (app.activeScreen or hs.screen.mainScreen()):frame()
    local w = math.max(90, math.min(BUTTON_WIDTH, f.w - EDGE_MARGIN * 2))
    local h = math.max(36, math.min(BUTTON_HEIGHT, f.h - EDGE_MARGIN * 2))
    local minX, minY = f.x + EDGE_MARGIN, f.y + EDGE_MARGIN
    local spanX = math.max(0, f.w - w - EDGE_MARGIN * 2)
    local spanY = math.max(0, f.h - h - EDGE_MARGIN * 2)
    local panel = panelFrame()
    local last = app.lastButtonRect
    local minDistance = math.min(f.w, f.h) * 0.38
    local best, bestScore = nil, -math.huge
    local function blocked(rect)
        if overlapsWithMargin(rect, panel, PANEL_CLEARANCE) then return true end
        for _, other in ipairs(occupied or {}) do
            if overlapsWithMargin(rect, other, EDGE_MARGIN) then return true end
        end
        return false
    end

    for _ = 1, RANDOM_TRIES do
        local rect = {
            x = math.floor(minX + math.random() * spanX),
            y = math.floor(minY + math.random() * spanY),
            w = w, h = h,
        }
        if not blocked(rect) then
            local distance = last and centerDistance(rect, last) or math.huge
            -- 找不到足够远的位置时，退而选相距最远的候选位置。
            if distance > bestScore then
                best, bestScore = rect, distance
            end
            if distance >= minDistance then
                app.lastButtonRect = rect
                return rect
            end
        end
    end

    -- 极小显示器等特殊情况：允许接近中央窗口，但尽量保证按钮在屏幕内。
    if not best then
        for _ = 1, RANDOM_TRIES do
            local rect = {
                x = math.floor(minX + math.random() * spanX),
                y = math.floor(minY + math.random() * spanY),
                w = w, h = h,
            }
            local distance = last and centerDistance(rect, last) or math.huge
            local score = distance
            if blocked(rect) then
                score = score - 100000
            end
            if score > bestScore then
                best, bestScore = rect, score
            end
        end
    end

    app.lastButtonRect = best
    return best
end

-- R/G/B 各自从 0～255 完全随机取值；仅在恰好重复上次颜色时重新抽取。
local function randomButtonColor()
    local bg
    repeat
        bg = string.format("#%02X%02X%02X", math.random(0, 255), math.random(0, 255), math.random(0, 255))
    until bg ~= app.lastButtonColor
    app.lastButtonColor = bg

    local r = tonumber(bg:sub(2, 3), 16)
    local g = tonumber(bg:sub(4, 5), 16)
    local b = tonumber(bg:sub(6, 7), 16)
    local luminance = 0.2126 * linearChannel(r)
                    + 0.7152 * linearChannel(g)
                    + 0.0722 * linearChannel(b)
    -- 临界值 0.179：选择黑白中对比度更高的颜色。
    local fg = luminance > 0.179 and "#000000" or "#FFFFFF"
    return { bg = bg, fg = fg }
end

local function htmlShell(content)
    return [[<!doctype html>
<html lang="zh-CN"><head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<style>
* { box-sizing: border-box; }
html, body { margin:0; height:100%; width:100%; background:transparent; overflow:hidden; }
body { font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif; color:#edf2f5; }
.panel {
  margin:6px; height:calc(100% - 12px); padding:26px 25px 21px;
  background:#24313a; border:1px solid #42515b; border-radius:19px;
  text-align:center; display:flex; flex-direction:column; align-items:stretch;
}
h1 { font-size:23px; margin:10px 0 10px; font-weight:650; }
p { margin:5px 0; line-height:1.5; }
.subtitle { color:#dae5e9; font-size:15px; }
.hint { color:#b6c7d0; font-size:13px; }
.icon { font-size:34px; }
.spacer { flex:1; min-height:12px; }
button { font:inherit; cursor:pointer; border:0; border-radius:11px; min-height:43px; font-weight:600; }
.back { margin-top:16px; background:#42525e; color:#f1f5f7; }
.footer { color:#98acb7; font-size:11px; margin-top:15px; }
.search-hint { margin-top:16px; font-size:15px; font-weight:600; color:#c8e1d5; }
.floating {
  width:calc(100% - 4px); height:calc(100% - 4px); min-height:0; margin:2px;
  border-radius:8px; border:1px solid transparent;
  box-shadow:0 3px 9px rgba(0,0,0,.27);
  cursor:default; font-size:12px; font-weight:700;
  display:flex; flex-direction:column; align-items:center; justify-content:center;
  line-height:1.12; gap:2px; padding:0 2px;
  white-space:nowrap; -webkit-user-select:none; user-select:none;
  opacity:1; -webkit-appearance:none; appearance:none;
}
.floating-label { pointer-events:none; }
.floating-status { pointer-events:none; font-size:9px; font-weight:500; opacity:.88; }
.floating.ready { cursor:pointer; outline:2px solid rgba(255,255,255,.72); outline-offset:-3px; }
.floating.ready:hover { filter:brightness(1.1); }
.floating.ready:active { filter:brightness(.92); }
</style></head><body>]] .. content .. [[
<script>
function send(action, minutes, session) {
  window.webkit.messageHandlers.blinkReminderBridge.postMessage({
    action: action, minutes: minutes || 0, session: session || 0
  });
}
</script></body></html>]]
end

local function confirmationLabel(stage)
    if app.hoverCount == 1 or stage == app.hoverCount - 1 then return "确认关闭" end
    return stage == 0 and "已休息" or "继续确认"
end

local function panelHTML(stage)
    local label = confirmationLabel(stage)
    local title = stage == 0 and "该让眼睛休息了" or string.format("第 %d / %d 次确认", stage + 1, app.hoverCount)
    local subtitle = stage == 0 and "自然眨眼几次，再看看远处约 20 秒。"
        or string.format("确认后，%g 分钟后重新提醒。", app.intervalMinutes)
    local extra
    if stage == 0 then
        local minutes = {}
        for _, value in ipairs(app.snoozeMinutes) do minutes[#minutes + 1] = tostring(value) end
        extra = #minutes > 0
            and '<p class="hint">忙碌中？寻找随机位置的「延后 ' .. table.concat(minutes, " / ") .. ' 分钟」按钮。</p>'
            or ""
    else
        extra = string.format('<button class="back" onclick="send(\'back\', 0, %d)">返回提醒</button>', app.buttonSession)
    end
    return htmlShell(string.format([[
<div class="panel">
  <div class="icon">👀</div>
  <h1>%s</h1>
  <p class="subtitle">%s</p>
  <p class="search-hint">寻找「%s」按钮，悬停 %g 秒后点击</p>
  <div class="spacer"></div>
  %s
  <div class="footer">不会自动关闭 · 共需 %d 次悬停确认 · 已完成 %d 次</div>
</div>]], title, subtitle, label, app.hoverSeconds, extra, app.hoverCount, stage))
end

-- 倒计时由 Lua 定时检测鼠标位置，WebView 只负责显示状态和处理点击。
-- 这样 Hammerspoon/网页窗口未获得焦点时，只要鼠标停在按钮上就会开始倒计时。
-- Lua 端对确认点击再次检查持续悬停时间，禁止提前跳过。
local function buttonHTML(stage)
    local label, action = confirmationLabel(stage), "confirm"
    local color = randomButtonColor()
    local style = string.format('background:%s;color:%s;', color.bg, color.fg)
    local html = string.format([[
<button class="floating" id="confirmation" style="%s" type="button" disabled>
  <span class="floating-label">%s</span>
  <span class="floating-status" id="hover-status">悬停 %g 秒</span>
</button>
<script>
(function () {
  const button = document.getElementById('confirmation');
  const status = document.getElementById('hover-status');
  const session = %d;
  const confirmAction = '%s';
  let lastClickAt = -Infinity;

  // 只能由 Lua 的系统级鼠标位置检测调用，不靠点击或 DOM mouseenter 启动。
  window.updateHoverCountdown = function (currentSession, message, ready) {
    if (currentSession !== session) return;
    status.textContent = message;
    button.disabled = !ready;
    button.classList.toggle('ready', ready);
  };

  button.addEventListener('click', function (event) {
    event.preventDefault();
    if (button.disabled) return;
    const now = performance.now();
    if (now - lastClickAt < 600) return;
    lastClickAt = now;
    send(confirmAction, 0, session);
  });
})();
</script>]], style, label, app.hoverSeconds, app.buttonSession, action)
    return htmlShell(html)
end

local function snoozeHTML(minutes)
    local letters, index = {}, 0
    local colorOffset = math.random(0, 1) -- 每次随机以黑字或白字开头
    for _, codepoint in utf8.codes(string.format("延后 %g 分钟", minutes)) do
        local char = utf8.char(codepoint)
        if char == " " then
            letters[#letters + 1] = char
        else
            index = index + 1
            local color = (index + colorOffset) % 2 == 1 and "#000000" or "#FFFFFF"
            letters[#letters + 1] = string.format('<span style="color:%s;">%s</span>', color, char)
        end
    end
    return htmlShell(string.format([[
<button class="floating" style="background:transparent;border:0;box-shadow:none;cursor:pointer;" type="button"
        onclick="send('snooze', %g, %d)"><span>%s</span></button>
]], minutes, app.buttonSession, table.concat(letters)))
end

local function makeWindow(rect)
    local view = hs.webview.new(rect, { javaScriptEnabled = true }, app.bridge)
    view:windowStyle({ "borderless" })  -- 不提供系统关闭按钮
    view:closeOnEscape(false)          -- Escape 不自动关闭
    view:deleteOnClose(false)
    view:transparent(true)
    view:level(hs.drawing.windowLevels.floating)
    return view
end

local function ensureViews()
    if not app.view then app.view = makeWindow(panelFrame()) end
    if not app.buttonView then
        local p = panelFrame()
        app.buttonView = makeWindow({ x = p.x, y = p.y, w = BUTTON_WIDTH, h = BUTTON_HEIGHT })
    end
end

-- 在整个 macOS 桌面检测鼠标坐标，不依赖窗口焦点或网页 mouseenter。
local function stopHoverTimer()
    if app.hoverTimer then
        app.hoverTimer:stop()
        app.hoverTimer = nil
    end
    app.hoverStartedNs = nil
    app.hoverStage = nil
    app.lastHoverDisplay = nil
end

local function mouseInsideRect(pos, rect)
    return rect and pos
       and pos.x >= rect.x and pos.x < rect.x + rect.w
       and pos.y >= rect.y and pos.y < rect.y + rect.h
end

local function pollHover()
    if not app.running or not app.buttonRect or not app.buttonView
       or not app.buttonView:isVisible() then return end

    local now = hs.timer.absoluteTime()
    local inside = mouseInsideRect(hs.mouse.absolutePosition(), app.buttonRect)
    local message, ready

    if inside then
        if app.hoverStartedNs == nil or app.hoverStage ~= app.stage then
            app.hoverStartedNs = now
            app.hoverStage = app.stage
        end
        local elapsed = (now - app.hoverStartedNs) / 1000000000
        ready = elapsed >= app.hoverSeconds
        local remaining = math.max(0, math.ceil(app.hoverSeconds - elapsed))
        message = ready and "可点击" or ("等待 " .. remaining .. " 秒")
    else
        app.hoverStartedNs = nil
        app.hoverStage = nil
        ready = false
        message = "悬停 " .. app.hoverSeconds .. " 秒"
    end

    -- 只在显示文字/可点击状态变化时更新 WebView。
    local displayKey = message .. ":" .. tostring(ready)
    if displayKey ~= app.lastHoverDisplay then
        app.lastHoverDisplay = displayKey
        local js = string.format(
            "if(window.updateHoverCountdown) window.updateHoverCountdown(%d, %q, %s);",
            app.buttonSession, message, tostring(ready))
        app.buttonView:evaluateJavaScript(js)
    end
end

local function hideViews()
    stopHoverTimer()
    app.buttonRect = nil
    if app.buttonView then app.buttonView:hide() end
    if app.view then app.view:hide() end
    for _, view in ipairs(app.snoozeViews) do view:hide() end
end

local function renderStage(stage)
    stopHoverTimer()
    app.stage = stage
    app.buttonSession = app.buttonSession + 1
    ensureViews()
    app.view:frame(panelFrame())
    app.view:html(panelHTML(stage))
    app.view:show():bringToFront(true)
    app.buttonRect = randomButtonFrame()
    app.buttonView:frame(app.buttonRect)
    app.buttonView:html(buttonHTML(stage))
    app.buttonView:show():bringToFront(true)
    for _, view in ipairs(app.snoozeViews) do view:hide() end
    if stage == 0 then
        local occupied = { app.buttonRect }
        for index, minutes in ipairs(app.snoozeMinutes) do
            local rect = randomButtonFrame(occupied)
            occupied[#occupied + 1] = rect
            local view = app.snoozeViews[index] or makeWindow(rect)
            app.snoozeViews[index] = view
            view:frame(rect)
            view:html(snoozeHTML(minutes))
            view:show():bringToFront(true)
        end
    end
    -- 不用先点一次按钮；立即开始检测鼠标是否进入按钮区域。
    app.hoverTimer = hs.timer.doEvery(0.1, pollHover)
    pollHover()
end

local showReminder
local function scheduleNext(seconds)
    stopTimer()
    app.reminderTimer = hs.timer.doAfter(seconds, function()
        if app.running then showReminder() end
    end)
end

showReminder = function()
    if not app.running then return end
    stopTimer()
    app.activeScreen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    renderStage(0)
end

local function handleMessage(message)
    local body = type(message) == "table" and (message.body or message) or nil
    if type(body) ~= "table" or not app.running then return end
    if not app.view or not app.view:isVisible() then return end

    local action = body.action
    -- 旧 WebView 页面可能异步发消息，不能影响当前提醒。
    if (action == "confirm" or action == "snooze" or action == "back")
       and tonumber(body.session) ~= app.buttonSession then return end

    if action == "confirm" then
        -- 使用单调时钟校验持续悬停；点击不能跳过计时或阶段。
        if app.hoverStage ~= app.stage or not app.hoverStartedNs then return end
        if not mouseInsideRect(hs.mouse.absolutePosition(), app.buttonRect) then return end
        if hs.timer.absoluteTime() - app.hoverStartedNs < app.hoverSeconds * 1000000000 then return end
        if app.stage + 1 < app.hoverCount then
            renderStage(app.stage + 1)
        else
            hideViews()
            app.stage = 0
            scheduleNext(app.intervalMinutes * 60)
        end
    elseif action == "snooze" and app.stage == 0 then
        local minutes = tonumber(body.minutes)
        for _, allowed in ipairs(app.snoozeMinutes) do
            if minutes == allowed then
                hideViews()
                scheduleNext(minutes * 60)
                break
            end
        end
    elseif action == "back" and app.stage ~= 0 then
        renderStage(0)
    end
end

function M.start(options)
    -- 重复 .start() 不会注册多个定时器/热键；修改配置请先 .stop()。
    if app.running then return M end
    options = options or {}
    local function positive(value, fallback, name)
        if value == nil then value = fallback end
        assert(type(value) == "number" and value > 0 and value < math.huge,
            name .. " 必须为正数")
        return value
    end
    local interval = positive(options.intervalMinutes, 20, "intervalMinutes")
    local seconds = positive(options.hoverSeconds, 10, "hoverSeconds")
    local count = positive(options.hoverCount, 3, "hoverCount")
    assert(count % 1 == 0, "hoverCount 必须为正整数")
    local snoozes, seen = {}, {}
    local configuredSnoozes = options.snoozeMinutes or { 1, 5, 10 }
    assert(type(configuredSnoozes) == "table", "snoozeMinutes 必须为数组")
    for _, value in ipairs(configuredSnoozes) do
        positive(value, nil, "snoozeMinutes 中的时间")
        assert(not seen[value], "snoozeMinutes 不能包含重复时间")
        snoozes[#snoozes + 1], seen[value] = value, true
    end
    app.intervalMinutes, app.hoverSeconds, app.hoverCount = interval, seconds, count
    app.snoozeMinutes = snoozes
    local hotkey = options.hotkey
    cleanupPreviousVersion()
    app.running = true
    app.stage = 0
    app.bridge = hs.webview.usercontent.new("blinkReminderBridge")
    app.bridge:setCallback(handleMessage)
    if hotkey and hotkey.bind ~= false then
        app.hotkey = hs.hotkey.bind(hotkey.mods, hotkey.key, showReminder)
    end
    _G.blinkReminderApp = app
    scheduleNext(app.intervalMinutes * 60)
    return M
end

function M.stop()
    stopTimer()
    stopHoverTimer()
    if app.hotkey then app.hotkey:delete(); app.hotkey = nil end
    if app.buttonView then app.buttonView:delete(); app.buttonView = nil end
    if app.view then app.view:delete(); app.view = nil end
    for _, view in ipairs(app.snoozeViews) do view:delete() end
    app.snoozeViews = {}
    if app.bridge then app.bridge:setCallback(nil); app.bridge = nil end
    app.stage = 0
    app.running = false
    app.activeScreen = nil
    app.lastButtonRect = nil
    app.lastButtonColor = nil
    app.buttonRect = nil
    app.buttonSession = app.buttonSession + 1
    app.hoverStartedNs = nil
    app.hoverStage = nil
    if rawget(_G, "blinkReminderApp") == app then _G.blinkReminderApp = nil end
    return M
end

function M.show()
    if not app.running then M.start() end
    showReminder()
    return M
end

return M
