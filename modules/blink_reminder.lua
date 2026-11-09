-- ~/.hammerspoon/modules/blink_reminder.lua
-- 每20分钟提醒一次；可延后1/5/10分钟；关闭须经过两次确认。
-- 关闭按钮和延后 1/5/10 分钟按钮在显示器随机位置出现、每次随机换色。
-- Hammerspoon 全局检测鼠标位置：无需点击，进入按钮区域立即开始连续悬停10秒计时。
-- 不自动关闭、不淡出、不创建菜单栏倒计时。
-- 使用：require("modules.blink_reminder").start({ hotkey = { mods = {...}, key = "..." } })
-- hotkey.bind = false 或不传快捷键时仅启动定时提醒，也可调用 .show() 手动显示。

local M = {}

local NORMAL_INTERVAL = 20 * 60
local PANEL_WIDTH, PANEL_HEIGHT = 500, 338
local BUTTON_WIDTH, BUTTON_HEIGHT = 112, 42  -- 更小的悬浮按钮；主体约 108 × 38 px
local HOVER_SECONDS = 10                 -- 必须连续悬停的秒数
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
    reminderTimer = nil,
    hoverTimer = nil,               -- 系统级鼠标位置轮询，不依赖 WebView 的 mouseenter
    stage = 0,                     -- 0: 提醒；1: 第一次确认；2: 第二次确认
    view = nil,                    -- 中央提醒窗口（含返回按钮）
    buttonView = nil,              -- 独立悬浮的随机确认按钮
    snoozeViews = {},              -- 三个独立随机位置/颜色的延后按钮
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

local function panelHTML(stage)
    if stage == 0 then
        return htmlShell([[
<div class="panel">
  <div class="icon">👀</div>
  <h1>该让眼睛休息了</h1>
  <p class="subtitle">自然眨眼几次，再看看远处约 20 秒。</p>
  <p class="search-hint">寻找「已休息」按钮，悬停 10 秒后点击</p>
  <div class="spacer"></div>
  <p class="hint">忙碌中？寻找随机位置的「延后 1 / 5 / 10 分钟」按钮。</p>
  <div class="footer">不会自动关闭 · 关闭需要两次确认</div>
</div>]])
    elseif stage == 1 then
        return htmlShell([[
<div class="panel">
  <div class="icon">✓</div>
  <h1>第一次确认</h1>
  <p class="subtitle">你确定已经休息过眼睛，要结束本次提醒吗？</p>
  <p class="search-hint">寻找「继续确认」，悬停 10 秒再点击</p>
  <div class="spacer"></div>
  <button class="back" onclick="send('back')">返回提醒</button>
  <div class="footer">确认按钮已重新随机移动 · 还需第二次确认</div>
</div>]])
    else
        return htmlShell([[
<div class="panel">
  <div class="icon">✓✓</div>
  <h1>第二次确认</h1>
  <p class="subtitle">再次确认结束本次提醒？</p>
  <p class="hint">确认后，20分钟后重新提醒。</p>
  <p class="search-hint">寻找「确认关闭」，悬停 10 秒再点击</p>
  <div class="spacer"></div>
  <button class="back" onclick="send('back')">返回提醒</button>
  <div class="footer">位置与上一次不同 · 不确认不会自动关闭</div>
</div>]])
    end
end

-- 倒计时由 Lua 定时检测鼠标位置，WebView 只负责显示状态和处理点击。
-- 这样 Hammerspoon/网页窗口未获得焦点时，只要鼠标停在按钮上就会开始倒计时。
-- Lua 端对确认点击再次检查持续悬停时间，禁止提前跳过。
local function buttonHTML(stage)
    local label, action
    if stage == 0 then
        label, action = "已休息", "closeStart"
    elseif stage == 1 then
        label, action = "继续确认", "confirm1"
    else
        label, action = "确认关闭", "confirm2"
    end
    local color = randomButtonColor()
    local style = string.format('background:%s;color:%s;', color.bg, color.fg)
    local html = string.format([[
<button class="floating" id="confirmation" style="%s" type="button" disabled>
  <span class="floating-label">%s</span>
  <span class="floating-status" id="hover-status">悬停 %d 秒</span>
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
</script>]], style, label, HOVER_SECONDS, app.buttonSession, action)
    return htmlShell(html)
end

local function snoozeHTML(minutes)
    local color = randomButtonColor()
    return htmlShell(string.format([[
<button class="floating" style="background:%s;color:%s;cursor:pointer;" type="button"
        onclick="send('snooze', %d, %d)">延后 %d 分钟</button>
]], color.bg, color.fg, minutes, app.buttonSession, minutes))
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
        ready = elapsed >= HOVER_SECONDS
        local remaining = math.max(0, math.ceil(HOVER_SECONDS - elapsed))
        message = ready and "可点击" or ("等待 " .. remaining .. " 秒")
    else
        app.hoverStartedNs = nil
        app.hoverStage = nil
        ready = false
        message = "悬停 " .. HOVER_SECONDS .. " 秒"
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
        for index, minutes in ipairs({ 1, 5, 10 }) do
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
    local isButtonAction = action == "closeStart" or action == "confirm1" or action == "confirm2"

    -- 旧 WebView 页面可能异步发消息，不能影响当前按钮的确认流程。
    if (isButtonAction or action == "snooze") and tonumber(body.session) ~= app.buttonSession then return end

    local isConfirmation = action == "closeStart" or action == "confirm1" or action == "confirm2"
    if isConfirmation then
        -- 使用单调时钟校验，不受系统时间更改影响。
        if app.hoverStage ~= app.stage or not app.hoverStartedNs then return end
        if not mouseInsideRect(hs.mouse.absolutePosition(), app.buttonRect) then return end
        if hs.timer.absoluteTime() - app.hoverStartedNs < HOVER_SECONDS * 1000000000 then return end
        app.hoverStartedNs = nil
        app.hoverStage = nil
    end

    if action == "snooze" and app.stage == 0 then
        local minutes = tonumber(body.minutes)
        if minutes == 1 or minutes == 5 or minutes == 10 then
            hideViews()
            scheduleNext(minutes * 60)
        end
    elseif action == "closeStart" and app.stage == 0 then
        renderStage(1)
    elseif action == "confirm1" and app.stage == 1 then
        renderStage(2)
    elseif action == "confirm2" and app.stage == 2 then
        hideViews()
        app.stage = 0
        scheduleNext(NORMAL_INTERVAL)
    elseif action == "back" and app.stage ~= 0 then
        renderStage(0)
    end
end

function M.start(options)
    local hotkey = options and options.hotkey
    -- 重复 .start() 不会注册多个定时器/热键。
    if app.running then return M end
    cleanupPreviousVersion()
    app.running = true
    app.stage = 0
    app.bridge = hs.webview.usercontent.new("blinkReminderBridge")
    app.bridge:setCallback(handleMessage)
    if hotkey and hotkey.bind ~= false then
        app.hotkey = hs.hotkey.bind(hotkey.mods, hotkey.key, showReminder)
    end
    _G.blinkReminderApp = app
    scheduleNext(NORMAL_INTERVAL)
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
