------------------------------------------------------------
-- window_resize.lua
--
-- 快捷键由 init.lua 传入 start({ hotkey = { mods = {...}, key = "..." } })
--
-- 1. 点击预置尺寸
-- 2. 输入：
--      1280x720
--      1280×720
--      1280 720
--      1280,720
--
-- 自动按 Retina scale 从 px 转换为 points
------------------------------------------------------------

local M = {}

------------------------------------------------------------
-- px -> points
------------------------------------------------------------

local function pxToPoints(win, wPx, hPx)

    local screen = win:screen()
    local mode = screen and screen:currentMode()

    local scale = (mode and mode.scale) or 1

    return wPx / scale, hPx / scale
end

------------------------------------------------------------
-- 解析尺寸
------------------------------------------------------------

local function parseSize(input)

    if not input then
        return nil
    end

    input = input:lower()

    local w, h =
        input:match("(%d+)%s*[x×,%s]%s*(%d+)")

    if not w or not h then
        return nil
    end

    w = tonumber(w)
    h = tonumber(h)

    if not w or not h or w <= 0 or h <= 0 then
        return nil
    end

    return w, h
end

------------------------------------------------------------
-- 调整窗口并居中
------------------------------------------------------------

local function resizeWindowToPxAndCenter(win, wPx, hPx)

    if not win then
        return
    end

    if win:isFullScreen() then
        return
    end

    local w, h = pxToPoints(win, wPx, hPx)

    local screen = win:screen()

    if not screen then
        return
    end

    -- 可用区域，不包括菜单栏 / Dock
    local sf = screen:frame()

    local x = sf.x + (sf.w - w) / 2
    local y = sf.y + (sf.h - h) / 2

    win:setFrame(
        hs.geometry.rect(
            x,
            y,
            w,
            h
        )
    )
end

------------------------------------------------------------
-- 预置尺寸
------------------------------------------------------------

local PRESET_RULES = {

    {
        title = "JetBrains 1200 × 760",
        w = 1200,
        h = 760
    },

    {
        title = "Chrome 1280 × 800",
        w = 1280,
        h = 800
    },

    {
        title = "Chrome 640 × 400",
        w = 640,
        h = 400
    },

}

------------------------------------------------------------
-- Chooser
------------------------------------------------------------

local targetWinId = nil
local chooser = nil
local resizeHotkey

------------------------------------------------------------
-- 创建 choices
------------------------------------------------------------

local function buildChoices(query)

    local choices = {}

    local wPx, hPx = parseSize(query)

    --------------------------------------------------------
    -- 自定义尺寸
    --------------------------------------------------------

    if wPx then

        table.insert(
            choices,
            {
                text = string.format(
                    "自定义：%d × %d（回车应用）",
                    wPx,
                    hPx
                ),

                subText =
                    "应用到热键触发时的聚焦窗口",

                custom = true,

                w = wPx,
                h = hPx,
            }
        )

    elseif query and query ~= "" then

        table.insert(
            choices,
            {
                text =
                    "格式不对：请输入 1280x720 / 1280 720 / 1280,720",

                subText =
                    "继续输入即可",

                valid = false,
            }
        )
    end

    --------------------------------------------------------
    -- 预置尺寸
    --------------------------------------------------------

    for _, r in ipairs(PRESET_RULES) do

        table.insert(
            choices,
            {
                text = r.title,

                subText =
                    string.format(
                        "%d × %d px",
                        r.w,
                        r.h
                    ),

                w = r.w,
                h = r.h,
            }
        )
    end

    return choices, (wPx ~= nil)
end

------------------------------------------------------------
-- 显示 chooser
------------------------------------------------------------

local function showResizeChooser()

    local win = hs.window.focusedWindow()

    if not win then
        return
    end

    if win:isFullScreen() then
        return
    end

    --------------------------------------------------------
    -- 保存当前窗口 ID
    --
    -- 防止 chooser 出来以后焦点变化
    --------------------------------------------------------

    targetWinId = win:id()

    chooser:query("")

    local choices = buildChoices("")

    chooser:choices(choices)

    chooser:show()
end

------------------------------------------------------------
-- 初始化
------------------------------------------------------------

function M.start(options)
    M.stop()
    local hotkey = options and options.hotkey

    --------------------------------------------------------
    -- Chooser
    --------------------------------------------------------

    chooser = hs.chooser.new(
        function(choice)

            if not choice then
                return
            end

            ------------------------------------------------
            -- 无效提示项
            ------------------------------------------------

            if choice.valid == false then
                return
            end

            ------------------------------------------------
            -- 找回热键触发时的窗口
            ------------------------------------------------

            local win =
                targetWinId
                and hs.window.get(targetWinId)
                or nil

            if not win then
                return
            end

            ------------------------------------------------
            -- 应用尺寸
            ------------------------------------------------

            if choice.w and choice.h then

                resizeWindowToPxAndCenter(
                    win,
                    choice.w,
                    choice.h
                )

                win:focus()
            end
        end
    )

    chooser:rows(10)

    chooser:searchSubText(true)

    chooser:placeholderText(
        "输入尺寸：1280x720 / 1280 720 / 1280,720，回车应用"
    )

    --------------------------------------------------------
    -- 输入改变
    --------------------------------------------------------

    chooser:queryChangedCallback(
        function(query)

            local choices, hasCustom =
                buildChoices(query)

            chooser:choices(choices)

            -- 如果识别出了尺寸，
            -- 自动选择第一项
            if hasCustom then
                chooser:selectedRow(1)
            end
        end
    )

    --------------------------------------------------------
    -- 输入无效
    --------------------------------------------------------

    chooser:invalidCallback(
        function()
            -- 不做处理
        end
    )

    --------------------------------------------------------
    -- 快捷键
    --------------------------------------------------------

    if hotkey and hotkey.bind ~= false then
        resizeHotkey = hs.hotkey.bind(
            hotkey.mods,
            hotkey.key,
            showResizeChooser
        )
    end

    return M
end

function M.stop()
    if resizeHotkey then resizeHotkey:delete(); resizeHotkey = nil end
    if chooser then chooser:hide(); chooser:delete(); chooser = nil end
    targetWinId = nil
    return M
end

return M
