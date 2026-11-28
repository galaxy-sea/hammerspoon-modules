-- 使用 Linux Cron 格式，按 Mac 本地时间执行：分 时 日 月 星期（0 或 7 为周日）。
-- url 和 cron 均可为字符串或数组；任一 Cron 匹配时打开全部链接，使用系统默认浏览器。
-- Cron 支持 *、列表、范围、步长，以及 JAN-DEC / SUN-SAT。
local M = {}
M.installation = {
    command = [[# 执行时间使用 Linux Cron 格式，按 Mac 本地时间执行。
# 分 时 日 月 星期（0 或 7 为周日）

0 9 * * *       # 每天 09:00
0 9 * * 1-5     # 周一至周五 09:00
0 14 * * 1     # 每周一 14:00
*/30 * * * *   # 每隔 30 分钟

# 同一计划可填写多个网址和多个执行时间。]],
}
M.parameters = {
    {
        key = "schedules",
        label = "网页计划", itemLabel = "计划", layout = "columns",
        default = {},
        fields = {
            { key = "enabled", label = "启用计划", default = true, header = true },
            { key = "url", label = "打开的网址", default = { "https://example.com" } },
            { key = "cron", label = "执行时间（Linux Cron：分 时 日 月 星期）", default = { "0 9 * * 1-5" } },
        },
    },
}
local running, jobs, timer, watcher = false, {}, nil, nil
local previousShutdown, shutdownHook
local generation = 0
local log = hs.logger.new("scheduled_webpages", "info")
local arm
local months = { JAN=1, FEB=2, MAR=3, APR=4, MAY=5, JUN=6, JUL=7, AUG=8, SEP=9, OCT=10, NOV=11, DEC=12 }
local weekdays = { SUN=0, MON=1, TUE=2, WED=3, THU=4, FRI=5, SAT=6 }

local function field(text, minimum, maximum, names, sunday)
    assert(text:sub(1, 1) ~= "," and text:sub(-1) ~= "," and not text:find(",,"), "Cron 列表不能为空")
    local values = {}
    local function number(token)
        local value = token:match("^%d+$") and tonumber(token) or (names and names[token:upper()])
        assert(value and value >= minimum and value <= maximum, "Cron 字段值越界或无效：" .. token)
        return value
    end
    for item in text:gmatch("[^,]+") do
        local base, stepText = item:match("^([^/]+)/(%d+)$")
        local step = 1
        if base then
            step = tonumber(stepText)
            assert(step > 0 and step < math.huge, "Cron 步长必须为正整数")
        else
            assert(not item:find("/", 1, true), "Cron 步长格式无效：" .. item)
            base = item
        end
        local first, last
        if base == "*" then
            first, last = minimum, maximum
        else
            local left, right = base:match("^([^%-]+)%-([^%-]+)$")
            if left then first, last = number(left), number(right)
            else first = number(base); last = stepText and maximum or first end
        end
        assert(first <= last, "Cron 范围必须递增：" .. item)
        for value = first, last, step do values[sunday and value % 7 or value] = true end
    end
    return { values = values, star = text:sub(1, 1) == "*" }
end

local function parse(expression)
    assert(type(expression) == "string", "cron 必须为字符串")
    local parts = {}
    for part in expression:gmatch("%S+") do parts[#parts + 1] = part end
    assert(#parts == 5, "cron 必须为五段：分 时 日 月 星期；当前为 " .. #parts .. " 段：" .. expression)
    return {
        field(parts[1], 0, 59), field(parts[2], 0, 23), field(parts[3], 1, 31),
        field(parts[4], 1, 12, months), field(parts[5], 0, 7, weekdays, true),
    }
end

local function matches(fields, date)
    if not fields[1].values[date.min] or not fields[2].values[date.hour] or not fields[4].values[date.month] then return false end
    local day, weekday = fields[3].values[date.day] == true, fields[5].values[date.wday - 1] == true
    -- 标准 Cron：日期和星期都被限定时，任意一项匹配即可；含 * 的字段采用同时匹配。
    if fields[3].star or fields[5].star then return day and weekday end
    return day or weekday
end

local function strings(value, name)
    if type(value) == "string" then value = { value } end
    assert(type(value) == "table" and #value > 0, name .. " 必须为字符串或非空字符串数组")
    local result, seen = {}, {}
    local count = #value
    for key in pairs(value) do
        assert(type(key) == "number" and key % 1 == 0 and key >= 1 and key <= count,
            name .. " 必须为连续数组")
    end
    for index = 1, count do
        local item = value[index]
        assert(type(item) == "string" and item ~= "", name .. " 数组元素必须为非空字符串")
        if not seen[item] then
            result[#result + 1], seen[item] = item, true
        end
    end
    return result
end

local function matchesAny(expressions, date)
    for _, fields in ipairs(expressions) do
        if matches(fields, date) then return true end
    end
    return false
end

local function check(now)
    now = math.floor(now) -- secondsSinceEpoch 含小数；Lua 的 os.date 要求整数时间戳。
    local date, minute = os.date("*t", now), math.floor(now / 60)
    for _, job in ipairs(jobs) do
        if matchesAny(job.fields, date) and job.lastMinute ~= minute then
            job.lastMinute = minute -- 一次触发只尝试一次，避免重复回调反复打开。
            local ok, opened = pcall(hs.urlevent.openURL, job.url)
            if ok and opened then
                job.lastOpenedAt = os.date("%Y-%m-%d %H:%M:%S", now)
                log.i("已打开定时网页：" .. job.label)
            else
                log.e("打开定时网页失败：" .. job.label .. (ok and "" or ("；" .. tostring(opened))))
            end
        end
    end
end

local function stopTimer()
    if timer then timer:stop(); timer = nil end
end

arm = function(target)
    stopTimer()
    if not running or #jobs == 0 then return end
    local now = hs.timer.secondsSinceEpoch()
    target = target or (math.floor(now / 60) + 1) * 60
    local currentGeneration = generation
    timer = hs.timer.doAfter(math.max(0.01, target - now), function()
        if not running or generation ~= currentGeneration then return end
        timer = nil
        local actual = hs.timer.secondsSinceEpoch()
        if actual < target then arm(target); return end -- 防止定时器提前触发。
        -- 休眠错过的分钟不补开，避免唤醒后一次打开大量网页。
        if actual - target < 60 then
            local ok, err = pcall(check, actual)
            if not ok then log.e(tostring(err)) end
        end
        arm()
    end)
end

function M.start(options)
    if running then return M end
    options = options or {}
    assert(type(options.schedules or {}) == "table", "schedules 必须为定时任务列表")
    local nextJobs = {}
    for index, schedule in ipairs(options.schedules or {}) do
        assert(type(schedule) == "table", "定时任务必须为 table")
        if schedule.enabled ~= false then
            local urls, crons = strings(schedule.url, "url"), strings(schedule.cron, "cron")
            assert(schedule.name == nil or type(schedule.name) == "string", "name 必须为字符串")
            local expressions = {}
            for _, expression in ipairs(crons) do expressions[#expressions + 1] = parse(expression) end
            for urlIndex, url in ipairs(urls) do
                assert(url:match("^https?://[^%s]+$"), "url 必须为完整的 http/https 网页地址")
                nextJobs[#nextJobs + 1] = { url = url, crons = crons, fields = expressions,
                    label = (schedule.name or ("任务 " .. index)) .. (#urls > 1 and (" / 链接 " .. urlIndex) or "") }
            end
        end
    end
    jobs, running = nextJobs, true
    generation = generation + 1
    if #jobs > 0 then
        watcher = hs.caffeinate.watcher.new(function(event)
            if running and event == hs.caffeinate.watcher.systemDidWake then
                generation = generation + 1
                arm()
            end
        end):start()
        arm()
    end
    local previous = hs.shutdownCallback
    previousShutdown = previous
    shutdownHook = function()
        M.stop()
        if previous then previous() end
    end
    hs.shutdownCallback = shutdownHook
    log.i("模块启动；已配置 " .. #jobs .. " 个 Cron 网页任务")
    return M
end

function M.stop()
    if not running then return end
    running = false
    generation = generation + 1
    stopTimer()
    if watcher then watcher:stop(); watcher = nil end
    if hs.shutdownCallback == shutdownHook then hs.shutdownCallback = previousShutdown end
    log.i("模块已停止")
end

function M.status()
    local schedules = {}
    for _, job in ipairs(jobs) do
        local crons = { table.unpack(job.crons) }
        schedules[#schedules + 1] = { name = job.label, url = job.url,
            cron = #crons == 1 and crons[1] or crons, lastOpenedAt = job.lastOpenedAt }
    end
    return { running = running, schedules = schedules }
end

return M
