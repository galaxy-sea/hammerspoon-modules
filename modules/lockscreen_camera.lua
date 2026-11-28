-- 单张 ImageSnap + 单调时钟；邮件与摄像头各自独立，所有报告先落盘再发送。
local M = {}
local IMAGESNAP = "/opt/homebrew/bin/imagesnap"
local MSMTP = "/opt/homebrew/bin/msmtp"
local STATE_ROOT = hs.configdir .. "/.lockscreen_camera"
-- 安装依赖：brew install imagesnap msmtp
M.installation = {
    command = [[# 先替换邮箱、SMTP 授权码和收件地址，再整体执行一次。
(
  set -e

  # 1. 安装依赖
  brew install imagesnap msmtp

  # 2. 追加 demo 账户配置
  umask 077
  cat >> "$HOME/.msmtprc" <<'EOF'

account demo
host smtp.qq.com
port 465
auth on
tls on
tls_starttls off
from your@qq.com
user your@qq.com
password YOUR_SMTP_AUTH_CODE
EOF
  chmod 600 "$HOME/.msmtprc"

  # 3. 发送测试邮件
  printf 'To: recipient@example.com\nSubject: Hammerspoon mail test\n\nMail configuration works.\n' | msmtp -a demo -t
)
# 收信成功后，GUI 中的邮件账户填写 demo，收件地址填写实际接收邮箱。]],
}

local home = os.getenv("HOME")
local defaults = {
    account = "default",
    deviceName = "", -- 留空使用系统设备名称，同时用作邮件标题前缀。
    to = {},
    ignoredSSIDs = {}, -- 连接到这些 Wi-Fi 时，不拍摄、不发信。
    photoRoot = home .. "/Downloads/异常解锁",
    lockedInterval = 5,
    afterUnlockInterval = 30,
    afterUnlockCount = 10,
    warmup = 0.5,
    cameraTimeout = 15,
    mailTimeout = 90,
    maxLockedSeconds = 0, -- 0：亮屏期间一直拍到解锁；黑屏始终结束本轮。
    maxMailBytes = 10 * 1024 * 1024, -- 包括 Base64 和 MIME 开销。
    retryInitial = 30,
    retryMax = 3600,
}
-- 仅描述现有配置；GUI 根据默认值推断控件，脚本本身不依赖 GUI。
M.parameters = {
    {
        label = "邮件通知",
        fields = {
            { key = "account", label = "邮件账户", default = defaults.account },
            { key = "deviceName", label = "设备名称（邮件标题前缀）", default = defaults.deviceName },
            { key = "to", label = "收件地址", default = defaults.to },
        },
    },
    {
        label = "拍照安排",
        fields = {
            { key = "photoRoot", label = "照片保存目录", default = defaults.photoRoot },
            { key = "lockedInterval", label = "锁屏拍照间隔（秒）", default = defaults.lockedInterval },
            { key = "afterUnlockCount", label = "解锁后拍照次数", default = defaults.afterUnlockCount },
            { key = "afterUnlockInterval", label = "解锁后拍照间隔（秒）", default = defaults.afterUnlockInterval },
        },
    },
    {
        label = "跳过的 Wi-Fi",
        fields = {
            { key = "ignoredSSIDs", label = "不拍照和发信的 Wi-Fi", default = defaults.ignoredSSIDs },
        },
    },
    {
        label = "高级设置", collapsed = true,
        fields = {
            { key = "warmup", label = "摄像头预热（秒）", default = defaults.warmup },
            { key = "cameraTimeout", label = "拍照超时（秒）", default = defaults.cameraTimeout },
            { key = "mailTimeout", label = "发信超时（秒）", default = defaults.mailTimeout },
            { key = "maxLockedSeconds", label = "锁屏拍照时长上限（秒，0 不限）", default = defaults.maxLockedSeconds },
            { key = "maxMailBytes", label = "单封邮件大小上限（字节）", default = defaults.maxMailBytes },
            { key = "retryInitial", label = "发信首次重试等待（秒）", default = defaults.retryInitial },
            { key = "retryMax", label = "发信重试等待上限（秒）", default = defaults.retryMax },
        },
    },
}
local cfg, watcher, wifiWatcher, previousShutdown, shutdownHook
local ignoredSSIDSet, currentSSID, wifiIgnored = {}, nil, false
local wifiInterface, wifiReadError, wifiLocationStatus, wifiLocationEnabled, wifiDiagnostic
local running, locked, awake, wakeHandled, followupArmed = false, false, false, false, false
local followupDir -- 同一轮锁屏与解锁后拍摄共用目录，报告和邮件仍各自独立。
local followupThreadRoot -- 两个阶段及分封邮件均引用本轮第一封邮件。
local session, camera, mailTask, mailTimer, mailTimeout, stateLock
local reports = {}
local log = hs.logger.new("lockscreen_camera", "info")
local finish, capture, pumpMail, begin, checkWiFi

local function monotonic() return hs.timer.absoluteTime() / 1e9 end
local function wall() return hs.timer.secondsSinceEpoch() end
local function stamp() return os.date("%Y-%m-%d_%H-%M-%S") end
local function stopTimer(t) if t then t:stop() end end
local function uuid() return (hs.host.uuid():gsub("[^%w]", "")) end
local function short(s) return tostring(s or ""):sub(1, 3000) end

local function note(level, message)
    log[level](message)
    if cfg then
        local f = io.open(STATE_ROOT .. "/camera.log", "a")
        if f then f:write(os.date("%Y-%m-%d %H:%M:%S "), level, " ", message, "\n"); f:close() end
    end
end

local function mkdir(path)
    if hs.fs.attributes(path, "mode") == "directory" then return end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then mkdir(parent) end
    assert(hs.fs.mkdir(path))
end

local function save(r)
    local path = STATE_ROOT .. "/reports/" .. r.id .. ".json"
    local f = assert(io.open(path .. ".tmp", "wb"))
    local ok, err = f:write(hs.json.encode(r, true))
    local closed, closeError = f:close()
    assert(ok, err); assert(closed, closeError)
    assert(os.rename(path .. ".tmp", path))
end

-- 同目录内的报告全部发送成功且不再拍摄时，才清理本轮照片和空目录。
-- 先持久化 sent，再删除文件；清理中断后可在重载时继续，绝不重新发信。
local function cleanupSentPhotos()
    local groups = {}
    for _, r in pairs(reports) do
        local group = groups[r.dir]
        if not group then group = {}; groups[r.dir] = group end
        group[#group + 1] = r
    end
    for directory, group in pairs(groups) do
        local ready = not (session and session.report.dir == directory)
            and not (followupArmed and followupDir == directory)
        for _, r in ipairs(group) do
            if r.status ~= "sent" then ready = false end
        end
        if ready then
            local ok, err = pcall(function()
                -- 不递归删除，只处理报告中明确记录的照片及其日期目录。
                assert(directory ~= cfg.photoRoot and directory:match("/%d%d%d%d%-%d%d%-%d%d_%d%d%-%d%d%-%d%d$"),
                    "拒绝清理非日期目录：" .. tostring(directory))
                local mode = hs.fs.symlinkAttributes(directory, "mode")
                assert(mode == nil or mode == "directory", "照片目录不是普通目录：" .. directory)
                for _, r in ipairs(group) do
                    for _, photo in ipairs(r.photos) do
                        assert(photo.path:match("^(.*)/[^/]+$") == directory,
                            "照片不在本轮目录：" .. photo.path)
                        if mode and hs.fs.symlinkAttributes(photo.path) then
                            local removed, why = os.remove(photo.path)
                            assert(removed, why)
                        end
                    end
                end
                -- remove 仅能删除空目录；未记录的文件不会被递归移除。
                if mode then
                    local removed, why = os.remove(directory)
                    assert(removed, why)
                end
                for _, r in ipairs(group) do
                    r.photosCleaned, r.photosCleanedText = true, stamp()
                    save(r)
                    reports[r.id] = nil
                end
            end)
            if ok then note("i", "已发送照片及日期目录已清理：" .. directory)
            else note("e", "清理已发送照片失败，保留记录待下次处理：" .. short(err)) end
        end
    end
end

local function readJSON(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("a"); f:close()
    return assert(hs.json.decode(data), "无效 JSON：" .. path)
end

-- 禁用退出回调后强制结束并回收，下一任务绝不与上一摄像头重叠。
local function killTask(task)
    if not task then return end
    task:setCallback(nil)
    if task:isRunning() then
        local pid = assert(tonumber(task:pid()))
        hs.execute("/bin/kill -KILL " .. string.format("%d", pid))
        task:waitUntilExit()
    end
end

local function validJPEG(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local size = f:seek("end")
    local valid = false
    if size and size >= 4 then
        f:seek("set", 0); local first = f:read(2)
        f:seek("end", -2); local last = f:read(2)
        valid = first == "\255\216" and last == "\255\217"
    end
    f:close()
    return valid, size
end

local function acceptPending(r)
    local p = r.pending
    if not p then return false end
    local valid, size = validJPEG(p.final)
    if not valid then
        valid, size = validJPEG(p.path)
        if valid then assert(os.rename(p.path, p.final)) end
    end
    if valid then
        r.photos[#r.photos + 1] = { path = p.final, size = size, started = p.started,
            completed = wall(), monotonicStart = p.monotonicStart, monotonicEnd = monotonic() }
    else
        os.remove(p.path)
    end
    r.pending = nil
    return valid
end

local function stopCapture(s)
    stopTimer(s.timer); stopTimer(s.timeout); stopTimer(s.limitTimer)
    s.timer, s.timeout, s.limitTimer = nil, nil, nil
    local task = camera; camera = nil
    killTask(task)
    -- 只纳入已经完整写出的 JPEG，未完成的临时文件删除。
    acceptPending(s.report)
    s.report.cameraPID = nil
end

-- MIME 预算预留正文/头部及每个附件开销；超大单图按原始字节拆分，绝不丢弃。
local function plan(r)
    local budget = math.floor((cfg.maxMailBytes - 65536) / 1.38)
    local parts, group, used = {}, {}, 0
    for _, photo in ipairs(r.photos) do
        local offset, piece = 0, 0
        while offset < photo.size do
            if budget - used <= 2048 then
                parts[#parts + 1] = group; group, used = {}, 0
            end
            local length = math.min(photo.size - offset, budget - used - 2048)
            local name = photo.path:match("([^/]+)$")
            if photo.size + 2048 > budget then
                -- 每个超大图片块单独一封，块号和偏移固定，可按序拼回原图。
                if #group > 0 then parts[#parts + 1] = group; group, used = {}, 0 end
                length = math.min(photo.size - offset, budget - 2048)
                piece = piece + 1
                name = name .. string.format(".part%06d", piece)
            elseif length < photo.size then
                parts[#parts + 1] = group; group, used = {}, 0
                length = photo.size
            end
            group[#group + 1] = { path = photo.path, name = name, offset = offset, length = length }
            used = used + length + 2048
            offset = offset + length
        end
    end
    if #group > 0 or #parts == 0 then parts[#parts + 1] = group end
    r.parts, r.nextPart, r.attempts, r.retryAt = parts, 1, 0, 0
end

local function safe(fn)
    return function(...)
        local ok, err = xpcall(fn, debug.traceback, ...)
        if not ok then
            note("e", short(err))
            if session then
                local ended, why = pcall(finish, "内部错误：" .. short(err))
                if not ended then note("e", "结束本轮失败，保留日志恢复：" .. short(why)) end
            end
            if running and not mailTask then
                stopTimer(mailTimer)
                mailTimer = hs.timer.doAfter(cfg.retryInitial, safe(pumpMail))
            end
        end
    end
end

local function encoded(s)
    -- 避免 hs.base64.encode(data, 76) 对大字符串反复拼接。
    local b = hs.base64.encode(s)
    return (b:gsub("............................................................" ..
        "................", "%0\r\n")) .. "\r\n"
end

local function header(s)
    -- RFC 2047，每行不超过 75 字符，按 UTF-8 字符边界切块。
    local words, chunk = {}, ""
    for _, code in utf8.codes(s) do
        local c = utf8.char(code)
        if #chunk + #c > 42 then words[#words + 1] = "=?UTF-8?B?" .. hs.base64.encode(chunk) .. "?="; chunk = "" end
        chunk = chunk .. c
    end
    if #chunk > 0 then words[#words + 1] = "=?UTF-8?B?" .. hs.base64.encode(chunk) .. "?=" end
    return table.concat(words, "\r\n ")
end

local function percent(s)
    return (s:gsub("([^%w%.%-_])", function(c) return string.format("%%%02X", c:byte()) end))
end

local function message(r)
    local part = r.nextPart
    local boundary = "lockscreen_" .. r.id .. "_" .. part
    local kind = r.kind == "locked" and (r.unlockedText and "锁屏及解锁时照片" or "锁屏期间照片") or "解锁后照片"
    local subject = cfg.deviceName .. " - 锁屏异常唤醒"
    local body = string.format("设备：%s\n阶段：%s\n开始：%s\n结束：%s\n原因：%s\n照片总数：%d\n本机目录：%s\n",
        cfg.deviceName, kind, r.startedText, r.endedText, short(r.reason), #r.photos, r.dir)
    local messageID = string.format("<%s.%d@lockscreen-camera.local>", r.id, part)
    -- 兼容旧队列；重试保持原 Message-ID，新邮件则通过引用归入同一会话。
    local threadRoot = r.threadRoot or string.format("<%s.1@lockscreen-camera.local>", r.id)
    local out = {
        "To: " .. table.concat(cfg.to, ", "), -- From 邮件头由 msmtp 根据账户补充。
        "Subject: " .. header(subject),
        "Date: " .. os.date("!%a, %d %b %Y %H:%M:%S +0000"),
        "Message-ID: " .. messageID,
    }
    if messageID ~= threadRoot then
        out[#out + 1] = "In-Reply-To: " .. threadRoot
        out[#out + 1] = "References: " .. threadRoot
    end
    local content = {
        "MIME-Version: 1.0", 'Content-Type: multipart/mixed; boundary="' .. boundary .. '"', "",
        "--" .. boundary, "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64", "", encoded(body),
    }
    for _, line in ipairs(content) do out[#out + 1] = line end
    for _, attachment in ipairs(r.parts[part]) do
        local f = assert(io.open(attachment.path, "rb"))
        assert(f:seek("set", attachment.offset))
        local data = f:read(attachment.length); f:close()
        assert(data and #data == attachment.length, "附件缺失或长度变化：" .. attachment.path)
        out[#out + 1] = "--" .. boundary
        out[#out + 1] = "Content-Type: application/octet-stream"
        out[#out + 1] = "Content-Disposition: attachment;"
        out[#out + 1] = " filename*=UTF-8''" .. percent(attachment.name)
        out[#out + 1] = "Content-Transfer-Encoding: base64"
        out[#out + 1] = ""
        out[#out + 1] = encoded(data)
    end
    out[#out + 1] = "--" .. boundary .. "--\r\n"
    local result = table.concat(out, "\r\n")
    assert(#result <= cfg.maxMailBytes, "MIME 超出 maxMailBytes；请调低预算或调高限制")
    return result
end

local function mailFailed(r, why)
    r.attempts = (r.attempts or 0) + 1
    local delay = math.min(cfg.retryMax, cfg.retryInitial * 2 ^ math.min(r.attempts - 1, 20))
    r.retryAt, r.lastMailError = wall() + delay, short(why)
    save(r)
    note("e", string.format("邮件失败 %s 第 %d 封；%d 秒后重试：%s", r.id, r.nextPart, delay, short(why)))
end

pumpMail = function()
    if not running or checkWiFi() or mailTask then return end
    cleanupSentPhotos()
    stopTimer(mailTimer); mailTimer = nil
    local selected, nextDue
    for _, r in pairs(reports) do
        if r.status == "pending" then
            if (r.retryAt or 0) <= wall() then
                if not selected or r.started < selected.started then selected = r end
            else
                nextDue = math.min(nextDue or math.huge, r.retryAt)
            end
        end
    end
    if not selected then
        if nextDue then mailTimer = hs.timer.doAfter(math.max(0.1, nextDue - wall()), safe(pumpMail)) end
        return
    end
    local r = selected
    local ok, data = pcall(function()
        assert(#cfg.to > 0, "未设置收件地址 to")
        if not r.parts then plan(r); save(r) end
        local data = message(r)
        local path = STATE_ROOT .. "/outgoing.eml"
        local f = assert(io.open(path, "wb"))
        local written, why = f:write(data)
        local closed, closeError = f:close()
        assert(written, why); assert(closed, closeError)
        return path
    end)
    if not ok then
        mailFailed(r, data)
        mailTimer = hs.timer.doAfter(0.1, safe(pumpMail)); return
    end
    local task
    -- hs.task:setInput 会在主线程同步写 pipe；SMTP 不读正文时可能卡住解锁事件。
    -- 通过文件重定向喂给 msmtp，shell 参数只走位置参数，exec 后仍是同一 PID。
    task = hs.task.new("/bin/sh", safe(function(code, _, stderr)
        if mailTask ~= task then return end
        mailTask = nil; stopTimer(mailTimeout); mailTimeout = nil
        os.remove(data)
        if code == 0 then
            r.nextPart, r.attempts, r.retryAt, r.lastMailError = r.nextPart + 1, 0, 0, nil
            if r.nextPart > #r.parts then r.status = "sent" end
            save(r)
            note("i", string.format("邮件已提交 SMTP %s 第 %d/%d 封", r.id, r.nextPart - 1, #r.parts))
            if r.status == "sent" then cleanupSentPhotos() end
        else mailFailed(r, "msmtp exit=" .. code .. " " .. short(stderr)) end
        mailTimer = hs.timer.doAfter(0.1, safe(pumpMail))
    end), { "-c", 'exec "$1" --account="$2" --read-recipients < "$3"',
        "lockscreen-camera-mail", MSMTP, cfg.account, data })
    mailTask = task
    if not task or not task:start() then
        mailTask = nil; mailFailed(r, "msmtp 无法启动：" .. MSMTP)
        mailTimer = hs.timer.doAfter(0.1, safe(pumpMail)); return
    end
    mailTimeout = hs.timer.doAfter(cfg.mailTimeout, safe(function()
        if mailTask ~= task then return end
        mailTask = nil; mailTimeout = nil; killTask(task)
        os.remove(data)
        mailFailed(r, "msmtp 发送超时；提交结果不确定，保留相同 Message-ID 重试")
        mailTimer = hs.timer.doAfter(0.1, safe(pumpMail))
    end))
end

finish = function(reason, ignoreReport)
    local s = session
    if not s then return end
    if not ignoreReport and checkWiFi() then return end
    session = nil -- 先失效，杀进程后的任何旧回调都不能继续拍摄。
    stopCapture(s)
    local r = s.report
    r.status, r.reason, r.endedText = ignoreReport and "ignored" or "pending", reason, stamp()
    reports[r.id] = r
    save(r) -- 即使退出时不能联网，也已成为可恢复的待发送报告。
    note("i", string.format("结束 %s %s：%d 张；%s", r.kind, r.id, #r.photos, reason))
    if running and not ignoreReport then
        stopTimer(mailTimer)
        mailTimer = hs.timer.doAfter(0.1, safe(pumpMail))
    end
    -- 补拍成功、失败或超时都会先发送第一阶段，再独立进行后续拍摄。
    -- 黑屏、重新锁屏或停止模块时，不启动后续任务。
    if not ignoreReport and s.followupDue and running and awake and not locked then
        begin("after_unlock", math.max(0, s.followupDue - monotonic()), r.dir, r.threadRoot)
    end
end

-- 读取当前连接，绝不使用附近扫描结果或已保存网络代替当前 SSID。
local function readWiFi()
    local ok, ssid = pcall(hs.wifi.currentNetwork)
    if ok and type(ssid) == "string" and ssid ~= "" then return ssid end
    local errors = {}
    if not ok then errors[#errors + 1] = short(ssid) end
    local listed, interfaces = pcall(hs.wifi.interfaces)
    if listed and type(interfaces) == "table" then
        -- 默认接口可能不可用；尝试每个实际无线接口，不假定一定是 en0。
        for _, interface in ipairs(interfaces) do
            local read, name = pcall(hs.wifi.currentNetwork, interface)
            if read and type(name) == "string" and name ~= "" then return name, interface end
            if not read then errors[#errors + 1] = interface .. ": " .. short(name) end
        end
        if #interfaces == 0 then errors[#errors + 1] = "未发现无线网卡" end
    else
        errors[#errors + 1] = "无线网卡枚举失败：" .. short(interfaces)
    end
    return nil, nil, #errors > 0 and table.concat(errors, "；") or nil
end

checkWiFi = function()
    local ssid, interface, readError = readWiFi()
    local diagnostic = ssid
    wifiLocationStatus, wifiLocationEnabled = nil, nil
    if not ssid then
        -- 只查询权限，不自动请求定位，避免模块启动时弹出授权窗口。
        local authorized, status = pcall(function() return hs.location.authorizationStatus() end)
        local enabled, services = pcall(function() return hs.location.servicesEnabled() end)
        wifiLocationStatus = authorized and status or "读取失败"
        if enabled then wifiLocationEnabled = services end
        diagnostic = "无法读取 Wi-Fi 名称（可能未连接或受系统权限限制）；定位授权："
            .. tostring(wifiLocationStatus) .. "；定位服务："
            .. (enabled and (services and "已开启" or "已关闭") or "读取失败")
        if readError then diagnostic = diagnostic .. "；接口错误：" .. readError end
        diagnostic = diagnostic .. "；无法匹配 Wi-Fi 跳过名单，继续正常监控"
    end
    local ignored = ssid ~= nil and ignoredSSIDSet[ssid] == true
    local wasIgnored = wifiIgnored
    local changed = diagnostic ~= wifiDiagnostic or ignored ~= wifiIgnored
    currentSSID, wifiIgnored = ssid, ignored
    wifiInterface, wifiReadError, wifiDiagnostic = interface, readError, diagnostic
    if changed then
        note(ssid and "i" or "w", "当前 Wi-Fi：" .. diagnostic
            .. (ssid and (ignored and "；匹配跳过名单" or "；正常监控") or ""))
    end
    if ignored then
        followupArmed, followupDir, followupThreadRoot = false, nil, nil
        finish("连接到跳过名单中的 Wi-Fi：" .. ssid .. "；保留本机照片，不发送本阶段通知", true)
        stopTimer(mailTimer); stopTimer(mailTimeout); mailTimer, mailTimeout = nil, nil
        local task = mailTask; mailTask = nil; killTask(task)
        if task then os.remove(STATE_ROOT .. "/outgoing.eml") end
    elseif wasIgnored and running then
        -- 无论由 Wi-Fi 通知还是系统事件先发现离网，都恢复已排队的邮件。
        wakeHandled = false
        stopTimer(mailTimer)
        mailTimer = hs.timer.doAfter(0.1, safe(pumpMail))
    end
    return ignored
end

capture = function(s)
    if not running or session ~= s or camera then return end
    if checkWiFi() then return end
    local needsLocked = s.report.kind == "locked" and not s.unlockSnapshot
    if not awake or (needsLocked and not locked) or (not needsLocked and locked) then
        finish("拍摄前系统状态已改变"); return
    end
    -- 即使定时器提前触发/系统时钟回拨，也不得提前拍或补拍漏掉的 tick。
    local remaining = s.due - monotonic()
    if remaining > 0 then
        s.timer = hs.timer.doAfter(math.max(0.01, remaining), safe(function() capture(s) end)); return
    end
    s.timer = nil
    local r = s.report
    local photoType = s.unlockSnapshot and "解锁" or (r.kind == "locked" and "锁屏" or "解锁后")
    local name = stamp() .. "-" .. photoType .. ".jpg"
    local final = r.dir .. "/" .. name
    -- 秒级命名发生碰撞（如系统时间回拨）时跳过，既不覆盖也不额外添加编号。
    if hs.fs.symlinkAttributes(final) then
        note("i", "跳过已存在的照片：" .. final)
        if s.unlockSnapshot then finish("系统确认解锁成功，解锁补拍文件已存在，跳过本次补拍"); return end
        s.due = monotonic() + s.interval
        s.timer = hs.timer.doAfter(s.interval, safe(function() capture(s) end))
        return
    end
    r.pending = { path = r.dir .. "/.pending-" .. r.id .. ".jpg", final = final,
        started = wall(), monotonicStart = monotonic() }
    save(r) -- 先记录目标文件，崩溃恢复也能找回已写完但未回调的照片。
    local args = { "-q", "-w", tostring(cfg.warmup) }
    args[#args + 1] = r.pending.path
    local task
    task = hs.task.new(IMAGESNAP, safe(function(code, _, stderr)
        if session ~= s or camera ~= task then return end
        if checkWiFi() then return end
        camera = nil; stopTimer(s.timeout); s.timeout = nil; r.cameraPID = nil
        if code ~= 0 then finish("ImageSnap exit=" .. code .. " " .. short(stderr)); return end
        if not acceptPending(r) then finish("ImageSnap 未输出完整 JPEG"); return end
        save(r)
        local photo = r.photos[#r.photos]
        note("i", string.format("照片 %s；单调时钟完成时间 %.3f", photo.path, photo.monotonicEnd))
        if s.unlockSnapshot then
            finish("系统确认解锁成功，已补拍解锁照片"); return
        end
        if r.kind == "after_unlock" and #r.photos >= cfg.afterUnlockCount then
            finish("解锁后已拍满 " .. cfg.afterUnlockCount .. " 张"); return
        end
        -- 从上一张完成起计算，确保真实拍照间隔至少为 5 / 30 秒。
        s.due = monotonic() + s.interval
        s.timer = hs.timer.doAfter(s.interval, safe(function() capture(s) end))
    end), args)
    camera = task
    if not task or not task:start() then
        camera = nil; finish("ImageSnap 无法启动：" .. IMAGESNAP); return
    end
    r.cameraPID = task:pid(); save(r)
    s.timeout = hs.timer.doAfter(cfg.cameraTimeout, safe(function()
        if session == s and camera == task then finish("ImageSnap 拍照超时（" .. cfg.cameraTimeout .. " 秒）") end
    end))
end

begin = function(kind, delay, directory, threadRoot, unlockDue)
    if checkWiFi() or session then return end
    local id, text = uuid(), stamp()
    local r = { id = id, kind = kind, status = "active", photos = {},
        started = wall(), startedText = text,
        dir = directory or cfg.photoRoot .. "/" .. text,
        threadRoot = threadRoot or string.format("<%s.1@lockscreen-camera.local>", id),
        unlockedText = unlockDue and stamp() or nil }
    if kind == "locked" and not unlockDue then followupDir, followupThreadRoot = r.dir, r.threadRoot end
    local s = { report = r, interval = kind == "locked" and cfg.lockedInterval or cfg.afterUnlockInterval,
        due = monotonic() + delay, unlockSnapshot = unlockDue ~= nil, followupDue = unlockDue }
    session = s
    reports[r.id] = r
    save(r)
    mkdir(r.dir)
    note("i", "开始 " .. kind .. " " .. id)
    if kind == "locked" and not s.unlockSnapshot and cfg.maxLockedSeconds > 0 then
        s.limitTimer = hs.timer.doAfter(cfg.maxLockedSeconds, safe(function()
            if session == s then finish("达到锁屏拍摄时长上限") end
        end))
    end
    if delay == 0 then capture(s)
    else s.timer = hs.timer.doAfter(delay, safe(function() capture(s) end)) end
end

local function event(eventType)
    if not running then return end
    checkWiFi()
    local w = hs.caffeinate.watcher
    note("i", "系统事件 " .. tostring(eventType))
    if eventType == w.screensDidLock then
        if locked then return end
        locked, followupArmed, wakeHandled = true, true, false
        followupDir, followupThreadRoot = nil, nil
        finish("解锁后再次锁屏，取消剩余拍摄")
        -- 锁屏本身不启动摄像头，等待屏幕唤醒事件。
    elseif eventType == w.screensDidWake then
        awake = true
        -- 快速解锁时，会话查询可能已显示未锁定，但解锁通知尚未送达。
        -- 保留已观察到的锁屏记录，确保随后仍能启动解锁后拍摄。
        if locked then followupArmed = true end
        local properties = hs.caffeinate.sessionProperties()
        if properties and properties.CGSSessionScreenIsLocked ~= nil then
            locked = properties.CGSSessionScreenIsLocked == true
        end
        if locked and not wakeHandled then
            wakeHandled, followupArmed = true, true
            begin("locked", 0)
        end
    elseif eventType == w.screensDidUnlock then
        -- 系统 screensDidUnlock 通知就是确认；重复通知不重置后续定时器。
        if not locked and not followupArmed then return end
        locked, awake = false, true
        local followupDue = monotonic() + cfg.afterUnlockInterval
        local directory = followupDir
        local threadRoot = followupThreadRoot
        followupArmed = false
        followupDir, followupThreadRoot = nil, nil
        if session and session.report.kind == "locked" then
            -- 停止旧的循环任务，保留报告；补拍的一张归入锁屏邮件后再结束。
            local s = session
            s.unlockSnapshot, s.followupDue = true, followupDue
            s.report.unlockedText = stamp()
            stopCapture(s)
            s.due = monotonic()
            capture(s)
        else
            -- 快速解锁尚无锁屏报告，或原阶段已经失败：仍补拍并通知。
            finish("系统确认解锁成功")
            begin("locked", 0, directory, threadRoot, followupDue)
        end
    elseif eventType == w.screensDidSleep or eventType == w.systemWillSleep
        or eventType == w.sessionDidResignActive then
        awake, wakeHandled, followupArmed = false, false, false
        followupDir, followupThreadRoot = nil, nil
        finish("显示器黑屏、系统休眠或用户会话离开，结束本轮")
    elseif eventType == w.systemWillPowerOff then
        M.stop("系统即将关机")
    end
    cleanupSentPhotos()
end

local function recover()
    for file in hs.fs.dir(STATE_ROOT .. "/reports") do
        if file:match("%.json$") then
            local ok, err = pcall(function()
                local r = readJSON(STATE_ROOT .. "/reports/" .. file)
                if r.status == "active" then
                    -- 仅清理命令行含本轮唯一临时文件名的旧进程，避免 PID 复用误杀。
                    if r.cameraPID and r.pending then
                        local pid = assert(tonumber(r.cameraPID))
                        local cmd = hs.execute("/bin/ps -p " .. string.format("%d", pid) .. " -o command=")
                        if cmd:find(r.pending.path, 1, true) then
                            hs.execute("/bin/kill -KILL " .. string.format("%d", pid))
                        end
                    end
                    acceptPending(r)
                    r.cameraPID, r.status = nil, "pending"
                    r.reason, r.endedText = "恢复未正常结束的拍摄；不自动恢复摄像头，仅发送已有照片", stamp()
                    save(r)
                end
                if not r.photosCleaned then reports[r.id] = r end
            end)
            if not ok then note("e", "恢复失败，保留原记录 " .. file .. "：" .. short(err)) end
        end
    end
end

function M.start(options)
    if running then return M end
    cfg = {}
    for k, v in pairs(defaults) do cfg[k] = v end
    -- 兼容旧配置中的已移除字段；固定数据目录、程序路径，并使用默认摄像头。
    local retired = { from = true, fromName = true, imagesnap = true, msmtp = true, stateRoot = true, device = true }
    for k, v in pairs(options or {}) do
        if not retired[k] then
            assert(defaults[k] ~= nil, "未知配置：" .. k)
            cfg[k] = v
        end
    end
    local name = options and options.deviceName
    if name == nil then name = options and options.fromName end -- 兼容旧版设备显示名称。
    cfg.deviceName = (type(name) == "string" and name ~= "" and name) or hs.host.localizedName() or "Mac"
    assert(type(cfg.ignoredSSIDs) == "table", "ignoredSSIDs 必须为 Wi-Fi 名称列表")
    ignoredSSIDSet = {}
    for _, ssid in ipairs(cfg.ignoredSSIDs) do
        assert(type(ssid) == "string" and ssid ~= "", "ignoredSSIDs 中的 Wi-Fi 名称不能为空")
        ignoredSSIDSet[ssid] = true
    end
    if type(cfg.to) == "string" then cfg.to = { cfg.to } end
    for _, name in ipairs({ "lockedInterval", "afterUnlockInterval", "afterUnlockCount", "cameraTimeout", "mailTimeout", "retryInitial", "retryMax" }) do
        assert(type(cfg[name]) == "number" and cfg[name] > 0, name .. " 必须 > 0")
    end
    assert(cfg.afterUnlockCount % 1 == 0, "afterUnlockCount 必须为整数")
    assert(cfg.maxMailBytes >= 128 * 1024, "maxMailBytes 至少为 128 KiB")
    assert(cfg.warmup >= 0 and cfg.maxLockedSeconds >= 0)
    for _, address in ipairs(cfg.to) do assert(not address:find("[\r\n]"), "无效收件地址") end
    mkdir(STATE_ROOT .. "/reports")
    -- 文件锁随进程退出释放，阻止同一队列的多个模块实例并行拍照/发信。
    stateLock = assert(io.open(STATE_ROOT .. "/instance.lock", "a"))
    if not hs.fs.lock(stateLock, "w") then stateLock:close(); stateLock = nil; error("lockscreen_camera 已有实例运行") end
    reports = {}
    recover()
    running, awake, wakeHandled, followupArmed = true, false, false, false
    followupDir, followupThreadRoot = nil, nil
    currentSSID, wifiIgnored = nil, false
    wifiInterface, wifiReadError, wifiLocationStatus, wifiLocationEnabled, wifiDiagnostic = nil, nil, nil, nil, nil
    checkWiFi()
    cleanupSentPhotos()
    local properties = hs.caffeinate.sessionProperties()
    locked = properties and properties.CGSSessionScreenIsLocked == true or false
    watcher = hs.caffeinate.watcher.new(safe(event)):start()
    wifiWatcher = hs.wifi.watcher.new(safe(function()
        -- 只恢复旧邮件，已取消的拍摄等待新一轮系统事件。
        checkWiFi()
    end)):start()
    previousShutdown = hs.shutdownCallback
    shutdownHook = function()
        local ok, err = pcall(M.stop, "Hammerspoon 重载或退出")
        if not ok then note("e", short(err)) end
        if previousShutdown then previousShutdown() end
    end
    hs.shutdownCallback = shutdownHook
    mailTimer = hs.timer.doAfter(0.1, safe(pumpMail))
    note("i", "模块启动；当前 Wi-Fi：" .. (currentSSID or "名称不可用，详见前面的 Wi-Fi 权限诊断")
        .. (wifiIgnored and "；跳过拍摄并暂停邮件" or "；等待锁屏显示器唤醒；邮件队列已恢复"))
    return M
end

function M.stop(reason)
    if not running then return end
    running = false
    followupArmed, followupDir, followupThreadRoot = false, nil, nil
    if watcher then watcher:stop(); watcher = nil end
    if wifiWatcher then wifiWatcher:stop(); wifiWatcher = nil end
    stopTimer(mailTimer); stopTimer(mailTimeout); mailTimer, mailTimeout = nil, nil
    local task = mailTask; mailTask = nil; killTask(task)
    os.remove(STATE_ROOT .. "/outgoing.eml")
    local ok, err = pcall(function()
        finish(reason or "模块停止")
        cleanupSentPhotos()
    end)
    if hs.shutdownCallback == shutdownHook then hs.shutdownCallback = previousShutdown end
    if stateLock then hs.fs.unlock(stateLock); stateLock:close(); stateLock = nil end
    note("i", "模块已停止；未发送邮件留待下次启动恢复")
    if not ok then error(err) end
end

function M.status()
    local pending = 0
    for _, r in pairs(reports) do if r.status == "pending" then pending = pending + 1 end end
    return { running = running, locked = locked, awake = awake,
        ssid = currentSSID, wifiIgnored = wifiIgnored,
        wifiInterface = wifiInterface, wifiReadError = wifiReadError,
        wifiLocationStatus = wifiLocationStatus, wifiLocationEnabled = wifiLocationEnabled,
        wifiDiagnostic = wifiDiagnostic,
        phase = session and (session.unlockSnapshot and "unlock" or session.report.kind) or "waiting",
        photos = session and #session.report.photos or 0,
        cameraRunning = camera ~= nil, mailRunning = mailTask ~= nil, pendingReports = pending }
end

return M
