-- ============================================================================
-- Client.lua - DFTI 人格测试 客户端模块
-- 页面：首页（选择测试集）→ 答题页（含选择统计）→ 结果页（含类型统计）
-- ============================================================================

---@diagnostic disable: undefined-global

local Client = {}

local UI = require("urhox-libs/UI")
local TestEngine = require("scripts.TestEngine")
local Shared = require("network.Shared")

local Settings = Shared.Settings
local EVENTS = Shared.EVENTS

-- ============================================================================
-- 全局变量
-- ============================================================================
local uiRoot_ = nil

-- 已注册的测试集列表
local quizRegistry_ = {}

-- 当前测试会话
---@type table|nil
local currentSession_ = nil

-- 页面状态："home" | "quiz" | "result"
local currentPage_ = "home"

-- 动画相关
local fadeIn_ = 0    -- 0~1 淡入进度
local fadeSpeed_ = 4 -- 淡入速度

-- 音效相关
local soundEnabled_ = true
---@type Node
local bgmNode_ = nil
---@type SoundSource
local bgmSource_ = nil
---@type Sound
local clickSound_ = nil
---@type Sound
local completeSound_ = nil
---@type Node
local sfxNode_ = nil

-- 颜色配置
local COLORS = {
    bg        = { 15, 15, 35, 255 },
    card      = { 28, 28, 56, 240 },
    cardLight = { 40, 40, 72, 240 },
    text      = { 240, 240, 255, 255 },
    textDim   = { 160, 165, 195, 200 },
    accent    = { 99, 102, 241, 255 },
    accentDim = { 79, 82, 200, 255 },
    border    = { 60, 60, 100, 80 },
    success   = { 34, 197, 94, 255 },
    danger    = { 239, 68, 68, 255 },
    white     = { 255, 255, 255, 255 },
    progressBg = { 40, 40, 72, 255 },
}

-- 版本号
local APP_VERSION = "v1.1.0"

-- 管理员用户
local ADMIN_USER_ID = 1779057459
local isAdmin_ = false

-- ============================================================================
-- 网络统计状态
-- ============================================================================

-- 答题统计状态
local showingStats_ = false      -- 是否正在显示统计
local pendingStats_ = nil        -- 等待中的统计数据 { questionId, counts, total }
local selectedOptionIndex_ = nil -- 当前选中的选项索引
local hasNextQuestion_ = nil     -- 选择后是否还有下一题

-- 当前答题记录（用于 TestCompleted 上报）
local answerRecords_ = {}        -- { { questionId=int, optionId=int }, ... }

-- 结果统计
local resultStats_ = nil         -- { typeCode, count, total }

-- 当前用户 ID（由服务端通过 CLIENT_INFO 事件下发）
local myUserId_ = nil

-- ============================================================================
-- 固定 UI 组件（全页面通用）
-- ============================================================================

local function BuildUserIdLabel()
    return nil
end

local function BuildVersionLabel()
    return UI.Label {
        text = APP_VERSION,
        fontSize = 10,
        fontColor = { 255, 255, 255, 40 },
        position = "absolute",
        bottom = 12,
        left = 12,
    }
end

-- ============================================================================
-- 测试集注册
-- ============================================================================

local function RegisterQuiz(quizData)
    table.insert(quizRegistry_, quizData)
    print("[Client] Registered quiz: " .. quizData.title)
end

local function LoadQuizzes()
    local dfti = require("scripts.quizzes.DFTIQuiz")
    RegisterQuiz(dfti)
    print("[Client] Total quizzes registered: " .. #quizRegistry_)
end

-- ============================================================================
-- 音效控制
-- ============================================================================

local function InitAudio()
    local bgm = cache:GetResource("Sound", "audio/music_1776005111942.ogg")
    if bgm then
        bgm.looped = true
        bgmNode_ = scene_:CreateChild("BGM")
        bgmSource_ = bgmNode_:CreateComponent("SoundSource")
        bgmSource_.soundType = "Music"
        bgmSource_.gain = 0.35
        bgmSource_:Play(bgm)
    end

    clickSound_ = cache:GetResource("Sound", "audio/sfx/click.ogg")
    completeSound_ = cache:GetResource("Sound", "audio/sfx/quiz_complete.ogg")
    sfxNode_ = scene_:CreateChild("SFX")
end

local function PlayClick()
    if not soundEnabled_ or not clickSound_ or not sfxNode_ then return end
    local src = sfxNode_:CreateComponent("SoundSource")
    src.soundType = "Effect"
    src.gain = 0.6
    src.autoRemoveMode = REMOVE_COMPONENT
    src:Play(clickSound_)
end

local function PlayComplete()
    if not soundEnabled_ or not completeSound_ or not sfxNode_ then return end
    local src = sfxNode_:CreateComponent("SoundSource")
    src.soundType = "Effect"
    src.gain = 0.7
    src.autoRemoveMode = REMOVE_COMPONENT
    src:Play(completeSound_)
end

local function ToggleSound()
    soundEnabled_ = not soundEnabled_
    if bgmSource_ then
        bgmSource_.gain = soundEnabled_ and 0.35 or 0.0
    end
end

-- ============================================================================
-- 网络通信
-- ============================================================================

--- 发送测试完成事件给服务端
local function SendTestCompleted(result, dimensionScores)
    local serverConn = network.serverConnection
    if not serverConn then
        print("[Client] WARNING: No server connection, cannot send TestCompleted")
        return
    end

    local payload = {
        result = result.type or "UNKNOWN",
        scores = dimensionScores or {},
        answers = answerRecords_,
    }

    local data = VariantMap()
    data["Data"] = Variant(cjson.encode(payload))
    serverConn:SendRemoteEvent(EVENTS.TEST_COMPLETED, true, data)
    print("[Client] Sent TestCompleted result=" .. (result.type or "?"))
end

--- 请求某题的统计数据（只读，服务端不写入数据库）
local function RequestQuestionStats(questionId, optionId)
    local serverConn = network.serverConnection
    if not serverConn then
        print("[Client] WARNING: No server connection, cannot request stats")
        return
    end
    local data = VariantMap()
    data["QuestionId"] = Variant(questionId)
    data["OptionId"] = Variant(optionId)
    serverConn:SendRemoteEvent(EVENTS.OPTION_SELECTED, true, data)
    print("[Client] Requested question stats q=" .. questionId .. " o=" .. optionId)
end

-- ============================================================================
-- 页面构建函数
-- ============================================================================

local function NavigateTo(page)
    currentPage_ = page
    fadeIn_ = 0

    local builders = {
        home = "BuildHomePage",
        quiz = "BuildQuizPage",
        result = "BuildResultPage",
        history_detail = "BuildHistoryDetailPage",
    }

    local builderName = builders[page]
    if not builderName then
        print("[Client] Unknown page: " .. page)
        return
    end

    local root = _G[builderName]()
    UI.SetRoot(root, true)
    uiRoot_ = root
end

-- ============================================================================
-- 上传题目弹窗
-- ============================================================================

local function UploadQuestion(questionText, options, onSuccess, onError)
    local userId = myUserId_ or "anonymous"

    local data = {
        question = questionText,
        options = options,
        userId = userId,
        timestamp = os.time(),
    }

    local jsonStr = cjson.encode(data)
    local key = "user_question_" .. os.time() .. "_" .. math.random(1000, 9999)

    clientCloud:Set(key, jsonStr, {
        ok = function()
            clientCloud:Get("question_keys", {
                ok = function(values, iscores)
                    local keyList = {}
                    if values.question_keys and type(values.question_keys) == "string" then
                        local ok2, parsed = pcall(cjson.decode, values.question_keys)
                        if ok2 and type(parsed) == "table" then
                            keyList = parsed
                        end
                    end
                    table.insert(keyList, key)
                    clientCloud:BatchSet()
                        :Set("question_keys", cjson.encode(keyList))
                        :Add("question_count", 1)
                        :Save("更新题目索引", {
                            ok = function()
                                if onSuccess then onSuccess() end
                            end,
                            error = function(code2, reason2)
                                if onSuccess then onSuccess() end
                            end,
                        })
                end,
                error = function(code, reason)
                    if onSuccess then onSuccess() end
                end,
            })
        end,
        error = function(code, reason)
            if onError then onError(reason) end
        end,
    })
end

local function OpenViewQuestionsModal()
    local modal = UI.Modal {
        title = "已上传题目",
        size = "md",
        closeOnOverlay = true,
        closeOnEscape = true,
        showCloseButton = true,
        backgroundColor = { 20, 20, 45, 250 },
        borderColor = { 60, 60, 100, 120 },
        borderWidth = 1,
        borderRadius = 16,
        onClose = function(self) self:Close() end,
    }

    local contentPanel = UI.Panel {
        width = "100%",
        gap = 12,
        padding = 4,
    }

    contentPanel:AddChild(UI.Label {
        text = "加载中...",
        fontSize = 14,
        fontColor = { 220, 170, 60, 200 },
        textAlign = "center",
        width = "100%",
    })

    modal:AddContent(UI.ScrollView {
        width = "100%",
        flexGrow = 1,
        flexShrink = 1,
        children = { contentPanel },
    })
    modal:Open()

    clientCloud:Get("question_keys", {
        ok = function(values, iscores)
            contentPanel:ClearChildren()

            local keyList = {}
            if values.question_keys and type(values.question_keys) == "string" then
                local ok2, parsed = pcall(cjson.decode, values.question_keys)
                if ok2 and type(parsed) == "table" then
                    keyList = parsed
                end
            end

            if #keyList == 0 then
                contentPanel:AddChild(UI.Panel {
                    width = "100%",
                    height = 120,
                    justifyContent = "center",
                    alignItems = "center",
                    children = {
                        UI.Label {
                            text = "暂无上传的题目",
                            fontSize = 14,
                            fontColor = { 255, 255, 255, 100 },
                        },
                    }
                })
                return
            end

            contentPanel:AddChild(UI.Label {
                text = "共 " .. #keyList .. " 道题目",
                fontSize = 12,
                fontColor = { 255, 255, 255, 100 },
                textAlign = "center",
                width = "100%",
            })

            local batch = clientCloud:BatchGet()
            for _, k in ipairs(keyList) do
                batch:Key(k)
            end
            batch:Fetch({
                ok = function(vals, iscrs)
                    for i = #keyList, 1, -1 do
                        local k = keyList[i]
                        local raw = vals[k]
                        if raw then
                            local qOk, qData = pcall(cjson.decode, raw)
                            if qOk and type(qData) == "table" then
                                local optWidgets = {}
                                for oi, opt in ipairs(qData.options or {}) do
                                    table.insert(optWidgets, UI.Panel {
                                        flexDirection = "row",
                                        alignItems = "center",
                                        gap = 8,
                                        children = {
                                            UI.Panel {
                                                width = 22, height = 22,
                                                borderRadius = 11,
                                                backgroundColor = { 220, 170, 60, 40 },
                                                justifyContent = "center",
                                                alignItems = "center",
                                                children = {
                                                    UI.Label {
                                                        text = string.char(64 + oi),
                                                        fontSize = 10,
                                                        fontColor = { 220, 170, 60, 200 },
                                                    }
                                                }
                                            },
                                            UI.Label {
                                                text = opt,
                                                fontSize = 13,
                                                fontColor = { 255, 255, 255, 180 },
                                                flexShrink = 1,
                                                whiteSpace = "normal",
                                            },
                                        }
                                    })
                                end

                                local timeStr = ""
                                if qData.timestamp then
                                    timeStr = os.date("%Y-%m-%d %H:%M", qData.timestamp)
                                end

                                contentPanel:AddChild(UI.Panel {
                                    width = "100%",
                                    padding = 14,
                                    backgroundColor = { 35, 35, 65, 200 },
                                    borderRadius = 12,
                                    borderWidth = 1,
                                    borderColor = { 60, 60, 100, 80 },
                                    gap = 10,
                                    children = {
                                        UI.Label {
                                            text = qData.question or "(无题目)",
                                            fontSize = 15,
                                            fontColor = { 255, 255, 255, 240 },
                                            whiteSpace = "normal",
                                            lineHeight = 1.4,
                                            width = "100%",
                                        },
                                        UI.Panel {
                                            width = "100%",
                                            gap = 6,
                                            paddingLeft = 4,
                                            children = optWidgets,
                                        },
                                        UI.Panel {
                                            width = "100%",
                                            flexDirection = "row",
                                            justifyContent = "space-between",
                                            children = {
                                                UI.Label {
                                                    text = timeStr,
                                                    fontSize = 11,
                                                    fontColor = { 255, 255, 255, 60 },
                                                },
                                                UI.Label {
                                                    text = "#" .. (#keyList - i + 1),
                                                    fontSize = 11,
                                                    fontColor = { 255, 255, 255, 60 },
                                                },
                                            }
                                        },
                                    }
                                })
                            end
                        end
                    end
                end,
                error = function(code, reason)
                    contentPanel:AddChild(UI.Label {
                        text = "加载题目详情失败: " .. tostring(reason),
                        fontSize = 13,
                        fontColor = { 239, 68, 68, 255 },
                        textAlign = "center",
                        width = "100%",
                    })
                end,
            })
        end,
        error = function(code, reason)
            contentPanel:ClearChildren()
            contentPanel:AddChild(UI.Label {
                text = "加载失败: " .. tostring(reason),
                fontSize = 13,
                fontColor = { 239, 68, 68, 255 },
                textAlign = "center",
                width = "100%",
            })
        end,
    })
end

-- ============================================================================
-- 最近测试历史
-- ============================================================================

-- 16 种人格完整信息
local TYPE_INFO = {
    ATCS = { animal = "远见的鹰", color = { 59, 130, 246, 255 }, operator = "露娜 / 银翼",
        description = "你是那种开局就喊「听我指挥」的人，关键是队友还真的会听。你擅长在进攻中保持清醒，一边架枪一边报点，脑子里永远有一张实时更新的战场地图。",
        traits = { "进攻指挥", "信息碾压", "团队大脑", "全局掌控" } },
    ATCI = { animal = "善战的狼", color = { 239, 68, 68, 255 }, operator = "红狼 / 威龙",
        description = "你和兄弟们就是一群饿狼。开局不废话，卡好点位直接冲，前排倒了后排补，打的就是配合和血性。",
        traits = { "狼群冲锋", "兄弟同心", "正面刚枪", "血性压制" } },
    ATRS = { animal = "奉献的鹤", color = { 34, 197, 94, 255 }, operator = "蜂医 / 蝶",
        description = "你是那个队友血量永远满的原因。进攻的时候你不抢人头，但你的烟雾弹永远扔在最关键的位置。你把「打辅助」变成了一门艺术。",
        traits = { "进攻奶妈", "烟雾大师", "无私续航", "幕后英雄" } },
    ATRI = { animal = "热血的野猪", color = { 251, 146, 60, 255 }, operator = "乌鲁鲁 / 蜂医",
        description = "你是队伍里啥都干的那个人——需要冲锋你冲锋，需要拉人你拉人。你凭直觉判断队伍现在最缺什么，然后立刻去补。",
        traits = { "万金油", "热心过头", "义气冲天", "有你真好" } },
    ALCS = { animal = "孤傲的豹", color = { 107, 114, 128, 255 }, operator = "骇爪 / 无名",
        description = "你是最危险的独行者。不报点不开麦，但击杀播报上你的名字出现得最频繁。你像骇爪一样无声，像无名一样致命。",
        traits = { "精准猎杀", "冷酷高效", "独狼战术", "来去无踪" } },
    ALCI = { animal = "威风的龙", color = { 220, 38, 38, 255 }, operator = "威龙 / 无名",
        description = "你就是那个让对面五个人都不敢推的存在。1v3是热身，1v5是日常，你不需要队友是因为队友跟不上你的节奏。",
        traits = { "一人成军", "绝境翻盘", "操作怪物", "天生战神" } },
    ALRS = { animal = "狡猾的狐", color = { 168, 85, 247, 255 }, operator = "骇爪 / 比特",
        description = "别人在打仗，你在发财。你是跑刀界的精算师，哪个房间刷什么物资、哪条路线最安全，你比地图设计师还清楚。",
        traits = { "闷声发财", "路线规划", "风险管控", "效率至上" } },
    ALRI = { animal = "随性的猫", color = { 236, 72, 153, 255 }, operator = "蛊 / 无名",
        description = "你打三角洲的方式就像猫逛后院——走到哪算哪，看到什么摸什么。你是唯一一个在烽火地带还能走出散步感的人。",
        traits = { "随心所欲", "佛系玩家", "独自漫游", "享受过程" } },
    DTCS = { animal = "沉稳的熊", color = { 120, 53, 15, 255 }, operator = "深蓝 / 牧羊人",
        description = "你是据点防守的教科书。每个路口架谁、每扇门朝哪开，你安排得比赛伊德守大坝还严密。你蹲在掩体后面像一座山。",
        traits = { "据点堡垒", "防守指挥", "稳如磐石", "绞肉机" } },
    DTCI = { animal = "阴险的蛇", color = { 16, 185, 129, 255 }, operator = "牧羊人 / 比特",
        description = "你不是在防守，你是在设局。每个角落都是你的陷阱，每扇门后面都可能有你的「惊喜」。对面打完一局只想说一个字：阴。",
        traits = { "陷阱大师", "阴险布局", "出其不意", "心理战专家" } },
    DTRS = { animal = "深谋的鸮", color = { 6, 182, 212, 255 }, operator = "蛊 / 银翼",
        description = "你在后方运筹帷幄，前线的兄弟们不知道为什么弹药永远够用、受伤总能及时回血。你不出现在击杀榜上，但每一场胜利都有你的影子。",
        traits = { "后方军师", "资源调度", "情报掌控", "隐形MVP" } },
    DTRI = { animal = "贪吃的猪", color = { 132, 204, 22, 255 }, operator = "蜂医 / 蛊",
        description = "你的游戏哲学很简单：搜就完了。队友在前面打生打死，你在后面默默把每个箱子舔得干干净净。但你总能在关键时刻掏出一个金装备。",
        traits = { "搜刮狂魔", "物资嗅觉", "快乐仓鼠", "关键时刻靠谱" } },
    DLCS = { animal = "冷血的蝎", color = { 71, 85, 105, 255 }, operator = "露娜 / 骇爪",
        description = "你趴在谁都想不到的角落，瞄准镜里是三百米外毫无察觉的目标。一枪，倒。换位置，继续。距离就是你的信仰，耐心就是你的武器。",
        traits = { "幽灵狙击", "极致耐心", "一击致命", "暗处死神" } },
    DLCI = { animal = "害群的马", color = { 202, 138, 4, 255 }, operator = "乌鲁鲁 / 深蓝",
        description = "你是对面的噩梦，偶尔也是队友的噩梦。你的行动逻辑连AI都算不出来。有时候单杀三人力挽狂澜，有时候被自己的陷阱炸死。",
        traits = { "不可预测", "鬼才走位", "既秀且坑", "战场变数" } },
    DLRS = { animal = "怯战的鼠", color = { 15, 118, 110, 255 }, operator = "骇爪 / 比特",
        description = "你是活到最后的人。不是因为你能打，是因为你根本不打。你把「苟」发展成了一门学问，但你总是笑到最后的那个。",
        traits = { "生存大师", "地图学者", "极致苟命", "笑到最后" } },
    DLRI = { animal = "摸鱼的仓鼠", color = { 249, 115, 22, 255 }, operator = "随缘选人",
        description = "你打游戏的核心诉求就是——别累着。找个安全角落搜搜东西，看看队友打架的直播，时不时捡个漏。你是「躺平学」代言人。",
        traits = { "咸鱼本鱼", "舔包达人", "躺平至上", "你们打我看" } },
}

-- 维度信息
local DIM_NAMES = {
    { id = "AD", nameA = "进攻 (A)", nameB = "防守 (D)" },
    { id = "TL", nameA = "团队 (T)", nameB = "独狼 (L)" },
    { id = "CR", nameA = "理性 (C)", nameB = "感性 (R)" },
    { id = "SI", nameA = "社交 (S)", nameB = "独处 (I)" },
}

--- 请求历史记录
local function RequestHistory()
    local serverConn = network.serverConnection
    if not serverConn then
        print("[Client] WARNING: No server connection, cannot request history")
        return
    end
    local data = VariantMap()
    serverConn:SendRemoteEvent(EVENTS.REQUEST_HISTORY, true, data)
    print("[Client] Requested history")
end

-- 缓存历史数据，供列表/详情切换时复用
local cachedHistory_ = nil
-- 当前查看的历史记录（用于全屏详情页）
local viewingHistoryRecord_ = nil
local viewingHistoryIndex_ = nil

-- ============================================================================
-- 人格榜
-- ============================================================================

-- 所有类型代号（用于排序）
local ALL_TYPE_CODES = {
    "ATCS", "ATCI", "ATRS", "ATRI",
    "ALCS", "ALCI", "ALRS", "ALRI",
    "DTCS", "DTCI", "DTRS", "DTRI",
    "DLCS", "DLCI", "DLRS", "DLRI",
}

local function RequestAllResults()
    local serverConn = network.serverConnection
    if not serverConn then return end
    serverConn:SendRemoteEvent(EVENTS.REQUEST_ALL_RESULTS, true, VariantMap())
    print("[Client] Requested all result stats")
end

local function OpenLeaderboardModal()
    local contentPanel = UI.Panel {
        width = "100%",
        gap = 10,
        children = {
            UI.Panel {
                width = "100%",
                height = 60,
                justifyContent = "center",
                alignItems = "center",
                children = {
                    UI.Label {
                        text = "加载中...",
                        fontSize = 14,
                        fontColor = { 255, 255, 255, 120 },
                    },
                },
            },
        },
    }

    local modal = UI.Modal {
        title = "人格榜",
        width = "92%",
        maxWidth = 420,
        maxHeight = "85%",
        backgroundColor = { 18, 18, 40, 245 },
        borderRadius = 16,
        onClose = function() _G._leaderboardModal = nil end,
    }
    modal:AddContent(UI.ScrollView {
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        children = { contentPanel },
    })
    modal:Show()

    _G._leaderboardModal = modal
    _G._leaderboardContent = contentPanel

    RequestAllResults()
end

function HandleAllResultsResp(eventType, eventData)
    local dataJson = eventData["Data"]:GetString()
    local ok, data = pcall(cjson.decode, dataJson)
    if not ok or not data then
        print("[Client] AllResultsResp: invalid data")
        return
    end

    local contentPanel = _G._leaderboardContent
    if not contentPanel then return end

    local total = data.total or 0
    print("[Client] AllResultsResp total=" .. total)

    contentPanel:ClearChildren()

    -- 标题统计
    contentPanel:AddChild(UI.Panel {
        width = "100%",
        alignItems = "center",
        paddingBottom = 8,
        children = {
            UI.Label {
                text = "共 " .. total .. " 人完成测试",
                fontSize = 13,
                fontColor = { 255, 255, 255, 100 },
            },
        },
    })

    -- 按人数降序排序
    local sorted = {}
    for _, code in ipairs(ALL_TYPE_CODES) do
        local count = data[code] or 0
        table.insert(sorted, { code = code, count = count })
    end
    table.sort(sorted, function(a, b) return a.count > b.count end)

    -- 找出最大值用于柱状图
    local maxCount = 1
    for _, item in ipairs(sorted) do
        if item.count > maxCount then maxCount = item.count end
    end

    for rank, item in ipairs(sorted) do
        local info = TYPE_INFO[item.code]
        if not info then goto continue end

        local c = info.color
        local pct = total > 0 and (item.count / total * 100) or 0
        local pctStr = pct >= 1 and string.format("%.0f%%", pct)
                    or pct > 0 and string.format("%.1f%%", pct)
                    or "0%"
        local barW = total > 0 and math.max(2, math.floor(item.count / maxCount * 100)) or 2

        -- 奖牌
        local medal = rank == 1 and "🥇" or rank == 2 and "🥈" or rank == 3 and "🥉" or ""

        contentPanel:AddChild(UI.Panel {
            width = "100%",
            flexDirection = "row",
            alignItems = "center",
            gap = 10,
            paddingVertical = 8,
            paddingHorizontal = 12,
            backgroundColor = rank <= 3 and { c[1], c[2], c[3], 15 } or { 0, 0, 0, 0 },
            borderRadius = 10,
            children = {
                -- 排名
                UI.Label {
                    text = medal ~= "" and medal or tostring(rank),
                    fontSize = medal ~= "" and 18 or 13,
                    fontColor = { 255, 255, 255, rank <= 3 and 220 or 80 },
                    width = 28,
                    textAlign = "center",
                },
                -- 类型信息
                UI.Panel {
                    flexGrow = 1,
                    flexShrink = 1,
                    flexBasis = 0,
                    gap = 4,
                    children = {
                        UI.Panel {
                            flexDirection = "row",
                            alignItems = "center",
                            gap = 6,
                            children = {
                                UI.Label {
                                    text = info.animal,
                                    fontSize = 14,
                                    fontColor = c,
                                },
                                UI.Label {
                                    text = item.code,
                                    fontSize = 10,
                                    fontColor = { c[1], c[2], c[3], 120 },
                                    letterSpacing = 1,
                                },
                            },
                        },
                        -- 柱状条
                        UI.Panel {
                            width = "100%",
                            height = 6,
                            borderRadius = 3,
                            backgroundColor = { 255, 255, 255, 15 },
                            overflow = "hidden",
                            children = {
                                UI.Panel {
                                    width = barW .. "%",
                                    height = "100%",
                                    borderRadius = 3,
                                    backgroundColor = c,
                                },
                            },
                        },
                    },
                },
                -- 人数 + 占比
                UI.Panel {
                    alignItems = "flex-end",
                    gap = 2,
                    children = {
                        UI.Label {
                            text = tostring(item.count) .. " 人",
                            fontSize = 13,
                            fontColor = COLORS.white,
                        },
                        UI.Label {
                            text = pctStr,
                            fontSize = 11,
                            fontColor = { c[1], c[2], c[3], 180 },
                        },
                    },
                },
            },
        })
        ::continue::
    end
end

--- 在弹窗内渲染历史列表
function ShowHistoryList(history)
    local contentPanel = _G._historyContentPanel
    if not contentPanel then return end

    contentPanel:ClearChildren()

    if #history == 0 then
        contentPanel:AddChild(UI.Panel {
            width = "100%",
            height = 120,
            justifyContent = "center",
            alignItems = "center",
            children = {
                UI.Label {
                    text = "暂无测试记录",
                    fontSize = 14,
                    fontColor = { 255, 255, 255, 100 },
                },
                UI.Label {
                    text = "完成一次测试后，记录会显示在这里",
                    fontSize = 12,
                    fontColor = { 255, 255, 255, 60 },
                    marginTop = 8,
                },
            },
        })
        return
    end

    contentPanel:AddChild(UI.Label {
        text = "共 " .. #history .. " 条记录（点击查看详情）",
        fontSize = 12,
        fontColor = { 255, 255, 255, 100 },
        textAlign = "center",
        width = "100%",
    })

    -- 倒序展示（最近的在前）
    for i = #history, 1, -1 do
        local record = history[i]
        local typeCode = record.result or "?"
        local info = TYPE_INFO[typeCode]
        local animal = info and info.animal or "未知"
        local typeColor = info and info.color or { 156, 163, 175, 255 }
        local displayIndex = #history - i + 1

        -- 格式化时间
        local timeStr = ""
        if record.timestamp then
            timeStr = os.date("%Y-%m-%d %H:%M", record.timestamp)
        end

        -- 维度标签
        local scoreWidgets = {}
        if record.scores then
            local dimLabels = { AD = { "进攻", "防守" }, TL = { "团队", "独狼" }, CR = { "理性", "感性" }, SI = { "社交", "独处" } }
            for dimId, names in pairs(dimLabels) do
                local score = record.scores[dimId]
                if score then
                    local label = score >= 0 and names[1] or names[2]
                    table.insert(scoreWidgets, UI.Panel {
                        paddingHorizontal = 8,
                        paddingVertical = 3,
                        backgroundColor = { typeColor[1], typeColor[2], typeColor[3], 25 },
                        borderRadius = 10,
                        children = {
                            UI.Label {
                                text = label,
                                fontSize = 10,
                                fontColor = { typeColor[1], typeColor[2], typeColor[3], 180 },
                            },
                        },
                    })
                end
            end
        end

        local cardChildren = {
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                justifyContent = "space-between",
                alignItems = "center",
                children = {
                    UI.Label {
                        text = "#" .. displayIndex,
                        fontSize = 11,
                        fontColor = { 255, 255, 255, 60 },
                    },
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        gap = 6,
                        children = {
                            UI.Label {
                                text = timeStr,
                                fontSize = 11,
                                fontColor = { 255, 255, 255, 60 },
                            },
                            UI.Label {
                                text = "›",
                                fontSize = 16,
                                fontColor = { 255, 255, 255, 40 },
                            },
                        },
                    },
                },
            },
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                alignItems = "center",
                gap = 10,
                children = {
                    UI.Panel {
                        paddingHorizontal = 10,
                        paddingVertical = 4,
                        backgroundColor = { typeColor[1], typeColor[2], typeColor[3], 50 },
                        borderRadius = 8,
                        children = {
                            UI.Label {
                                text = typeCode,
                                fontSize = 13,
                                fontColor = typeColor,
                                letterSpacing = 2,
                            },
                        },
                    },
                    UI.Label {
                        text = animal,
                        fontSize = 16,
                        fontColor = { 255, 255, 255, 240 },
                    },
                },
            },
        }

        if #scoreWidgets > 0 then
            table.insert(cardChildren, UI.Panel {
                flexDirection = "row",
                flexWrap = "wrap",
                gap = 6,
                children = scoreWidgets,
            })
        end

        -- 捕获循环变量
        local capturedRecord = record
        local capturedIndex = displayIndex

        contentPanel:AddChild(UI.Panel {
            width = "100%",
            padding = 14,
            backgroundColor = { 35, 35, 65, 200 },
            borderRadius = 12,
            borderWidth = 1,
            borderColor = { typeColor[1], typeColor[2], typeColor[3], 40 },
            gap = 10,
            transition = "backgroundColor 0.15s easeOut, scale 0.15s easeOut",
            onPointerEnter = function(event, widget)
                widget:SetStyle({ backgroundColor = { 45, 45, 80, 230 }, scale = 1.01 })
            end,
            onPointerLeave = function(event, widget)
                widget:SetStyle({ backgroundColor = { 35, 35, 65, 200 }, scale = 1.0 })
            end,
            onClick = function(self)
                PlayClick()
                viewingHistoryRecord_ = capturedRecord
                viewingHistoryIndex_ = capturedIndex
                -- 关闭弹窗，跳转到全屏详情页
                if _G._historyModal then
                    _G._historyModal:Close()
                    _G._historyModal = nil
                end
                NavigateTo("history_detail")
            end,
            children = cardChildren,
        })
    end
end

--- 打开历史记录弹窗
local function OpenHistoryModal()
    cachedHistory_ = nil

    local modal = UI.Modal {
        title = "最近测试",
        size = "md",
        closeOnOverlay = true,
        closeOnEscape = true,
        showCloseButton = true,
        backgroundColor = { 20, 20, 45, 250 },
        borderColor = { 60, 60, 100, 120 },
        borderWidth = 1,
        borderRadius = 16,
        onClose = function(self) self:Close() end,
    }

    local contentPanel = UI.Panel {
        width = "100%",
        gap = 12,
        padding = 4,
    }

    contentPanel:AddChild(UI.Label {
        text = "加载中...",
        fontSize = 14,
        fontColor = { 220, 170, 60, 200 },
        textAlign = "center",
        width = "100%",
    })

    modal:AddContent(UI.ScrollView {
        width = "100%",
        flexGrow = 1,
        flexShrink = 1,
        children = { contentPanel },
    })
    modal:Open()

    _G._historyModal = modal
    _G._historyContentPanel = contentPanel

    RequestHistory()
end

--- 收到服务端的历史记录响应
function HandleHistoryResp(eventType, eventData)
    local dataJson = eventData["Data"]:GetString()
    local ok, data = pcall(cjson.decode, dataJson)
    if not ok or not data then
        print("[Client] HistoryResp: invalid data")
        return
    end

    local history = data.history or {}
    print("[Client] HistoryResp count=" .. #history)

    cachedHistory_ = history
    ShowHistoryList(history)
end

local function OpenFeedbackModal()
    local feedbackText = ""
    local modal
    local statusLabel

    statusLabel = UI.Label {
        text = "",
        fontSize = 12,
        fontColor = { 34, 197, 94, 255 },
        textAlign = "center",
        width = "100%",
        height = 0,
    }

    local submitBtn = UI.Panel {
        width = "100%",
        height = 48,
        borderRadius = 24,
        backgroundColor = { 100, 120, 220, 255 },
        justifyContent = "center",
        alignItems = "center",
        marginTop = 8,
        transition = "scale 0.15s easeOut, backgroundColor 0.15s easeOut",
        onPointerEnter = function(event, widget)
            widget:SetStyle({ scale = 1.02, backgroundColor = { 120, 140, 235, 255 } })
        end,
        onPointerLeave = function(event, widget)
            widget:SetStyle({ scale = 1.0, backgroundColor = { 100, 120, 220, 255 } })
        end,
        onClick = function(self)
            PlayClick()
            if feedbackText == "" or #feedbackText < 2 then
                statusLabel:SetStyle({
                    text = "请输入反馈内容",
                    fontColor = { 239, 68, 68, 255 },
                    height = 20,
                })
                return
            end

            statusLabel:SetStyle({
                text = "提交中...",
                fontColor = { 220, 170, 60, 255 },
                height = 20,
            })

            local data = {
                feedback = feedbackText,
                userId = myUserId_ or "anonymous",
                timestamp = os.time(),
            }

            local jsonStr = cjson.encode(data)
            local key = "user_feedback_" .. os.time() .. "_" .. math.random(1000, 9999)

            clientCloud:Set(key, jsonStr, {
                ok = function()
                    statusLabel:SetStyle({
                        text = "感谢你的反馈！",
                        fontColor = { 34, 197, 94, 255 },
                        height = 20,
                    })
                    local closeTimer = 0
                    SubscribeToEvent("Update", function(_, ed)
                        closeTimer = closeTimer + ed["TimeStep"]:GetFloat()
                        if closeTimer >= 1.5 then
                            UnsubscribeFromEvent("Update")
                            if modal then modal:Close() end
                        end
                    end)
                end,
                fail = function(reason)
                    statusLabel:SetStyle({
                        text = "提交失败: " .. tostring(reason),
                        fontColor = { 239, 68, 68, 255 },
                        height = 20,
                    })
                end,
            })
        end,
        children = {
            UI.Label {
                text = "提交反馈",
                fontSize = 15,
                fontColor = { 255, 255, 255, 255 },
            },
        },
    }

    modal = UI.Modal {
        title = "反馈与建议",
        size = "md",
        closeOnOverlay = true,
        closeOnEscape = true,
        showCloseButton = true,
        backgroundColor = { 20, 20, 45, 250 },
        borderColor = { 60, 60, 100, 120 },
        borderWidth = 1,
        borderRadius = 16,
        onClose = function(self) self:Close() end,
    }

    modal:AddContent(UI.ScrollView {
        width = "100%",
        flexGrow = 1,
        flexShrink = 1,
        children = {
            UI.Panel {
                width = "100%",
                gap = 16,
                padding = 4,
                children = {
                    UI.Label {
                        text = "你的反馈会帮助我们做得更好",
                        fontSize = 12,
                        fontColor = { 255, 255, 255, 120 },
                        whiteSpace = "normal",
                        lineHeight = 1.4,
                    },
                    UI.Panel {
                        width = "100%",
                        gap = 6,
                        children = {
                            UI.Label {
                                text = "反馈内容",
                                fontSize = 13,
                                fontColor = { 255, 255, 255, 200 },
                            },
                            UI.TextField {
                                width = "100%",
                                placeholder = "说说你的想法、建议或遇到的问题……",
                                value = "",
                                fontSize = 14,
                                backgroundColor = { 40, 40, 70, 255 },
                                borderColor = { 60, 60, 100, 120 },
                                borderWidth = 1,
                                borderRadius = 8,
                                paddingHorizontal = 12,
                                paddingVertical = 10,
                                fontColor = { 240, 240, 255, 255 },
                                placeholderColor = { 255, 255, 255, 60 },
                                minHeight = 100,
                                multiline = true,
                                onChange = function(self, text)
                                    feedbackText = text
                                end,
                            },
                        },
                    },
                    statusLabel,
                    submitBtn,
                },
            },
        },
    })

    modal:Open()
end

local function OpenUploadModal()
    local questionText = ""
    local optionTexts = { "", "" }
    local MAX_OPTIONS = 7

    ---@type table|nil
    local modal = nil
    ---@type table|nil
    local optionsContainer = nil
    ---@type table|nil
    local addBtn = nil
    ---@type table|nil
    local statusLabel = nil
    ---@type table|nil
    local uploadBtn = nil

    local function BuildOptionRow(index)
        return UI.Panel {
            id = "option_row_" .. index,
            width = "100%",
            flexDirection = "row",
            alignItems = "center",
            gap = 8,
            children = {
                UI.Panel {
                    width = 28, height = 28,
                    borderRadius = 14,
                    backgroundColor = { 220, 170, 60, 60 },
                    justifyContent = "center",
                    alignItems = "center",
                    children = {
                        UI.Label {
                            text = string.char(64 + index),
                            fontSize = 12,
                            fontColor = { 220, 170, 60, 255 },
                        }
                    }
                },
                UI.TextField {
                    flexGrow = 1,
                    flexShrink = 1,
                    flexBasis = 0,
                    placeholder = "选项 " .. string.char(64 + index),
                    value = optionTexts[index] or "",
                    fontSize = 14,
                    backgroundColor = { 40, 40, 70, 255 },
                    borderColor = { 60, 60, 100, 120 },
                    borderWidth = 1,
                    borderRadius = 8,
                    onChange = function(self, value)
                        optionTexts[index] = value
                    end,
                },
            }
        }
    end

    local function RebuildOptions()
        if not optionsContainer then return end
        optionsContainer:ClearChildren()
        for i = 1, #optionTexts do
            optionsContainer:AddChild(BuildOptionRow(i))
        end
        if addBtn then
            addBtn:SetVisible(#optionTexts < MAX_OPTIONS)
        end
    end

    modal = UI.Modal {
        title = "上传题目",
        size = "md",
        closeOnOverlay = true,
        closeOnEscape = true,
        showCloseButton = true,
        backgroundColor = { 20, 20, 45, 250 },
        borderColor = { 60, 60, 100, 120 },
        borderWidth = 1,
        borderRadius = 16,
        onClose = function(self) self:Close() end,
    }

    statusLabel = UI.Label {
        text = "",
        fontSize = 12,
        fontColor = { 34, 197, 94, 255 },
        textAlign = "center",
        width = "100%",
        height = 0,
    }

    optionsContainer = UI.Panel {
        width = "100%",
        gap = 10,
    }

    addBtn = UI.Panel {
        width = "100%",
        height = 40,
        borderRadius = 10,
        borderWidth = 1,
        borderStyle = "dashed",
        borderColor = { 220, 170, 60, 80 },
        backgroundColor = { 220, 170, 60, 15 },
        justifyContent = "center",
        alignItems = "center",
        flexDirection = "row",
        gap = 6,
        transition = "backgroundColor 0.15s easeOut",
        onPointerEnter = function(event, widget)
            widget:SetStyle({ backgroundColor = { 220, 170, 60, 35 } })
        end,
        onPointerLeave = function(event, widget)
            widget:SetStyle({ backgroundColor = { 220, 170, 60, 15 } })
        end,
        onClick = function(self)
            PlayClick()
            if #optionTexts < MAX_OPTIONS then
                table.insert(optionTexts, "")
                RebuildOptions()
            end
        end,
        children = {
            UI.Label {
                text = "+",
                fontSize = 18,
                fontColor = { 220, 170, 60, 200 },
            },
            UI.Label {
                text = "添加选项",
                fontSize = 13,
                fontColor = { 220, 170, 60, 200 },
            },
        },
    }

    uploadBtn = UI.Panel {
        width = "100%",
        height = 48,
        borderRadius = 24,
        backgroundColor = { 220, 170, 60, 255 },
        justifyContent = "center",
        alignItems = "center",
        marginTop = 8,
        transition = "scale 0.15s easeOut, backgroundColor 0.15s easeOut",
        onPointerEnter = function(event, widget)
            widget:SetStyle({ scale = 1.02, backgroundColor = { 235, 185, 75, 255 } })
        end,
        onPointerLeave = function(event, widget)
            widget:SetStyle({ scale = 1.0, backgroundColor = { 220, 170, 60, 255 } })
        end,
        onClick = function(self)
            PlayClick()
            if questionText == "" then
                statusLabel:SetStyle({
                    text = "请输入题目内容",
                    fontColor = { 239, 68, 68, 255 },
                    height = 20,
                })
                return
            end

            local validOptions = {}
            for _, opt in ipairs(optionTexts) do
                if opt ~= "" then
                    table.insert(validOptions, opt)
                end
            end

            if #validOptions < 2 then
                statusLabel:SetStyle({
                    text = "请至少填写2个选项",
                    fontColor = { 239, 68, 68, 255 },
                    height = 20,
                })
                return
            end

            statusLabel:SetStyle({
                text = "上传中...",
                fontColor = { 220, 170, 60, 255 },
                height = 20,
            })

            UploadQuestion(questionText, validOptions,
                function()
                    statusLabel:SetStyle({
                        text = "上传成功！感谢你的贡献",
                        fontColor = { 34, 197, 94, 255 },
                        height = 20,
                    })
                    local closeTimer = 0
                    SubscribeToEvent("Update", function(_, ed)
                        closeTimer = closeTimer + ed["TimeStep"]:GetFloat()
                        if closeTimer >= 1.5 then
                            UnsubscribeFromEvent("Update")
                            if modal then modal:Close() end
                        end
                    end)
                end,
                function(reason)
                    statusLabel:SetStyle({
                        text = "上传失败: " .. tostring(reason),
                        fontColor = { 239, 68, 68, 255 },
                        height = 20,
                    })
                end
            )
        end,
        children = {
            UI.Label {
                text = "上传题目",
                fontSize = 15,
                fontColor = { 20, 20, 40, 255 },
            },
        },
    }

    modal:AddContent(UI.ScrollView {
        width = "100%",
        flexGrow = 1,
        flexShrink = 1,
        children = {
            UI.Panel {
                width = "100%",
                gap = 16,
                padding = 4,
                children = {
                    UI.Label {
                        text = "你的题目将提交到题库，通过审核后可被其他玩家看到",
                        fontSize = 12,
                        fontColor = { 255, 255, 255, 120 },
                        whiteSpace = "normal",
                        lineHeight = 1.4,
                    },
                    UI.Panel {
                        width = "100%",
                        gap = 6,
                        children = {
                            UI.Label {
                                text = "题目内容",
                                fontSize = 13,
                                fontColor = { 255, 255, 255, 200 },
                            },
                            UI.TextField {
                                width = "100%",
                                placeholder = "请输入你的题目，例如：队友挂了你会怎么做？",
                                value = "",
                                fontSize = 14,
                                backgroundColor = { 40, 40, 70, 255 },
                                borderColor = { 60, 60, 100, 120 },
                                borderWidth = 1,
                                borderRadius = 8,
                                onChange = function(self, value)
                                    questionText = value
                                end,
                            },
                        },
                    },
                    UI.Panel {
                        width = "100%",
                        gap = 6,
                        children = {
                            UI.Label {
                                text = "选项",
                                fontSize = 13,
                                fontColor = { 255, 255, 255, 200 },
                            },
                            optionsContainer,
                            addBtn,
                        },
                    },
                    statusLabel,
                    uploadBtn,
                },
            },
        },
    })

    RebuildOptions()
    modal:Open()
end

-- ============================================================================
-- 首页
-- ============================================================================

local function BuildSoundToggle()
    local label = UI.Label {
        text = soundEnabled_ and "ON" or "OFF",
        fontSize = 11,
        fontColor = soundEnabled_ and { 220, 170, 60, 255 } or { 255, 255, 255, 80 },
    }

    return UI.Panel {
        position = "absolute",
        top = 16,
        right = 16,
        width = 40, height = 40,
        borderRadius = 20,
        backgroundColor = { 0, 0, 0, 100 },
        justifyContent = "center",
        alignItems = "center",
        transition = "backgroundColor 0.15s easeOut",
        onPointerEnter = function(event, widget)
            widget:SetStyle({ backgroundColor = { 0, 0, 0, 160 } })
        end,
        onPointerLeave = function(event, widget)
            widget:SetStyle({ backgroundColor = { 0, 0, 0, 100 } })
        end,
        onClick = function(self)
            ToggleSound()
            label:SetStyle({
                text = soundEnabled_ and "ON" or "OFF",
                fontColor = soundEnabled_ and { 220, 170, 60, 255 } or { 255, 255, 255, 80 },
            })
        end,
        children = { label },
    }
end

function BuildHomePage()
    local quiz = quizRegistry_[1]

    -- 重置答题状态
    showingStats_ = false
    pendingStats_ = nil
    selectedOptionIndex_ = nil
    answerRecords_ = {}
    resultStats_ = nil

    return UI.Panel {
        width = "100%",
        height = "100%",
        backgroundImage = "image/dfti_home_banner_20260412132653.png",
        backgroundFit = "cover",
        children = {
            UI.Panel {
                width = "100%",
                height = "100%",
                backgroundGradient = {
                    direction = "to bottom",
                    colors = {
                        { 0, 0, 0, 0 },
                        { 0, 0, 0, 40 },
                        { 0, 0, 0, 180 },
                        { 12, 12, 30, 240 },
                    }
                },
                justifyContent = "flex-end",
                alignItems = "center",
                paddingHorizontal = 24,
                paddingBottom = 40,
                children = {
                    UI.Panel {
                        width = "100%",
                        maxWidth = 400,
                        alignItems = "center",
                        gap = 4,
                        marginBottom = 16,
                        children = {
                            UI.Label {
                                text = "三角洲行动",
                                fontSize = 28,
                                fontColor = COLORS.white,
                            },
                            UI.Label {
                                text = "人格测试",
                                fontSize = 28,
                                fontColor = COLORS.white,
                            },
                        },
                    },
                    UI.Label {
                        text = "DFTI",
                        fontSize = 40,
                        fontColor = { 220, 170, 60, 255 },
                        letterSpacing = 10,
                    },
                    UI.Label {
                        text = "Delta Force Type Indicator",
                        fontSize = 11,
                        fontColor = { 255, 255, 255, 100 },
                        letterSpacing = 2,
                    },
                    UI.Label {
                        text = "四维度十六型  找到你的战场人格",
                        fontSize = 13,
                        fontColor = { 255, 255, 255, 160 },
                        marginTop = 4,
                        marginBottom = 16,
                    },
                    quiz and UI.Panel {
                        width = "100%",
                        maxWidth = 400,
                        height = 52,
                        borderRadius = 26,
                        backgroundColor = { 220, 170, 60, 255 },
                        justifyContent = "center",
                        alignItems = "center",
                        transition = "scale 0.15s easeOut, backgroundColor 0.15s easeOut",
                        onPointerEnter = function(event, widget)
                            widget:SetStyle({ scale = 1.03, backgroundColor = { 235, 185, 75, 255 } })
                        end,
                        onPointerLeave = function(event, widget)
                            widget:SetStyle({ scale = 1.0, backgroundColor = { 220, 170, 60, 255 } })
                        end,
                        onClick = function(self)
                            PlayClick()
                            currentSession_ = TestEngine.CreateSession(quiz)
                            answerRecords_ = {}
                            resultStats_ = nil
                            NavigateTo("quiz")
                        end,
                        children = {
                            UI.Label {
                                text = "开始测试",
                                fontSize = 16,
                                fontColor = { 20, 20, 40, 255 },
                            },
                        },
                    } or nil,
                    quiz and UI.Label {
                        text = #quiz.questions .. " 道题  ·  约 3 分钟",
                        fontSize = 11,
                        fontColor = { 255, 255, 255, 80 },
                        marginTop = 8,
                    } or nil,
                    -- 最近测试按钮
                    UI.Panel {
                        width = "100%",
                        maxWidth = 400,
                        height = 44,
                        borderRadius = 22,
                        backgroundColor = { 0, 0, 0, 0 },
                        borderWidth = 1,
                        borderColor = { 220, 170, 60, 120 },
                        justifyContent = "center",
                        alignItems = "center",
                        marginTop = 10,
                        transition = "scale 0.15s easeOut, backgroundColor 0.15s easeOut, borderColor 0.15s easeOut",
                        onPointerEnter = function(event, widget)
                            widget:SetStyle({ scale = 1.03, backgroundColor = { 220, 170, 60, 20 }, borderColor = { 220, 170, 60, 200 } })
                        end,
                        onPointerLeave = function(event, widget)
                            widget:SetStyle({ scale = 1.0, backgroundColor = { 0, 0, 0, 0 }, borderColor = { 220, 170, 60, 120 } })
                        end,
                        onClick = function(self)
                            PlayClick()
                            OpenHistoryModal()
                        end,
                        children = {
                            UI.Label {
                                text = "最近测试",
                                fontSize = 14,
                                fontColor = { 220, 170, 60, 220 },
                            },
                        },
                    },
                    -- 人格榜按钮
                    UI.Panel {
                        width = "100%",
                        maxWidth = 400,
                        height = 44,
                        borderRadius = 22,
                        backgroundColor = { 0, 0, 0, 0 },
                        borderWidth = 1,
                        borderColor = { 220, 170, 60, 120 },
                        justifyContent = "center",
                        alignItems = "center",
                        marginTop = 10,
                        transition = "scale 0.15s easeOut, backgroundColor 0.15s easeOut, borderColor 0.15s easeOut",
                        onPointerEnter = function(event, widget)
                            widget:SetStyle({ scale = 1.03, backgroundColor = { 220, 170, 60, 20 }, borderColor = { 220, 170, 60, 200 } })
                        end,
                        onPointerLeave = function(event, widget)
                            widget:SetStyle({ scale = 1.0, backgroundColor = { 0, 0, 0, 0 }, borderColor = { 220, 170, 60, 120 } })
                        end,
                        onClick = function(self)
                            PlayClick()
                            OpenLeaderboardModal()
                        end,
                        children = {
                            UI.Label {
                                text = "人格榜",
                                fontSize = 14,
                                fontColor = { 220, 170, 60, 220 },
                            },
                        },
                    },
                    UI.Panel {
                        marginTop = 24,
                        flexDirection = "row",
                        gap = 12,
                        justifyContent = "center",
                        children = {
                            UI.Panel {
                                paddingHorizontal = 20,
                                paddingVertical = 10,
                                borderRadius = 20,
                                backgroundColor = { 30, 30, 55, 200 },
                                borderWidth = 1,
                                borderColor = { 220, 170, 60, 80 },
                                flexDirection = "row",
                                alignItems = "center",
                                justifyContent = "center",
                                gap = 6,
                                transition = "backgroundColor 0.15s easeOut, scale 0.15s easeOut, borderColor 0.15s easeOut",
                                onPointerEnter = function(event, widget)
                                    widget:SetStyle({ backgroundColor = { 40, 40, 65, 230 }, scale = 1.05, borderColor = { 220, 170, 60, 150 } })
                                end,
                                onPointerLeave = function(event, widget)
                                    widget:SetStyle({ backgroundColor = { 30, 30, 55, 200 }, scale = 1.0, borderColor = { 220, 170, 60, 80 } })
                                end,
                                onClick = function(self)
                                    PlayClick()
                                    OpenUploadModal()
                                end,
                                children = {
                                    UI.Label {
                                        text = "+",
                                        fontSize = 16,
                                        fontColor = { 220, 170, 60, 220 },
                                    },
                                    UI.Label {
                                        text = "上传题目",
                                        fontSize = 13,
                                        fontColor = { 220, 170, 60, 220 },
                                    },
                                },
                            },
                            UI.Panel {
                                paddingHorizontal = 20,
                                paddingVertical = 10,
                                borderRadius = 20,
                                backgroundColor = { 30, 30, 55, 200 },
                                borderWidth = 1,
                                borderColor = { 100, 120, 220, 80 },
                                flexDirection = "row",
                                alignItems = "center",
                                justifyContent = "center",
                                gap = 6,
                                transition = "backgroundColor 0.15s easeOut, scale 0.15s easeOut, borderColor 0.15s easeOut",
                                onPointerEnter = function(event, widget)
                                    widget:SetStyle({ backgroundColor = { 40, 40, 65, 230 }, scale = 1.05, borderColor = { 100, 120, 220, 150 } })
                                end,
                                onPointerLeave = function(event, widget)
                                    widget:SetStyle({ backgroundColor = { 30, 30, 55, 200 }, scale = 1.0, borderColor = { 100, 120, 220, 80 } })
                                end,
                                onClick = function(self)
                                    PlayClick()
                                    OpenFeedbackModal()
                                end,
                                children = {
                                    UI.Label {
                                        text = "反馈与建议",
                                        fontSize = 13,
                                        fontColor = { 140, 160, 240, 220 },
                                    },
                                },
                            },
                        },
                    },
                },
            },
            BuildSoundToggle(),
            BuildUserIdLabel(),
            BuildVersionLabel(),
        }
    }
end

-- ============================================================================
-- 答题页
-- ============================================================================

--- 构建选项按钮（选择时从服务端读统计但不写入，测试结束后统一上传）
local function BuildOptionButton(option, index, quizColor, question)
    local letters = { "A", "B", "C", "D", "E", "F" }
    local letter = letters[index] or tostring(index)
    local origIdx = option.originalIndex or index

    -- 统计进度条（初始宽度 0）
    local statsBar = UI.Panel {
        width = "0%",
        height = "100%",
        borderRadius = 2,
        backgroundColor = { quizColor[1], quizColor[2], quizColor[3], 120 },
        transition = "width 0.4s easeOut",
    }

    -- 统计文字
    local statsLabel = UI.Label {
        text = "",
        fontSize = 11,
        fontColor = { quizColor[1], quizColor[2], quizColor[3], 180 },
        textAlign = "right",
        width = "100%",
    }

    -- 统计区域容器（初始隐藏）
    local statsContainer = UI.Panel {
        width = "100%",
        marginTop = 8,
        gap = 4,
        opacity = 0,
        transition = "opacity 0.3s easeOut",
        children = {
            UI.Panel {
                width = "100%",
                height = 4,
                borderRadius = 2,
                backgroundColor = { 255, 255, 255, 10 },
                overflow = "hidden",
                children = { statsBar },
            },
            statsLabel,
        }
    }

    local downX, downY = 0, 0
    local CLICK_THRESHOLD = 10  -- 拖动超过10像素则不触发点击

    local btn = UI.Panel {
        id = "option_" .. index,
        width = "100%",
        minHeight = 56,
        justifyContent = "center",
        padding = 16,
        backgroundColor = COLORS.card,
        borderRadius = 12,
        borderWidth = 1,
        borderColor = COLORS.border,
        transition = "scale 0.15s easeOut, backgroundColor 0.15s easeOut, borderColor 0.15s easeOut",

        onPointerEnter = function(event, widget)
            if not showingStats_ then
                widget:SetStyle({
                    scale = 1.02,
                    backgroundColor = COLORS.cardLight,
                    borderColor = { quizColor[1], quizColor[2], quizColor[3], 120 },
                })
            end
        end,
        onPointerLeave = function(event, widget)
            if not showingStats_ then
                widget:SetStyle({
                    scale = 1.0,
                    backgroundColor = COLORS.card,
                    borderColor = COLORS.border,
                })
            end
        end,

        onPointerDown = function(event, widget)
            downX = event.x or 0
            downY = event.y or 0
        end,

        onPointerUp = function(event, widget)
            -- 严格判定：拖动超过阈值则不触发点击
            local dx = math.abs((event.x or 0) - downX)
            local dy = math.abs((event.y or 0) - downY)
            if dx > CLICK_THRESHOLD or dy > CLICK_THRESHOLD then return end

            if showingStats_ then return end  -- 已选过，不可再选

            PlayClick()
            showingStats_ = true
            selectedOptionIndex_ = index

            -- 记录答案并推进 TestEngine
            local questionOrigIdx = question.originalIndex or 1
            local optionOrigIdx = option.originalIndex or index

            hasNextQuestion_ = TestEngine.Answer(currentSession_, index)

            -- 记录到 answerRecords（测试结束后统一上传）
            table.insert(answerRecords_, {
                questionId = questionOrigIdx,
                optionId = optionOrigIdx,
            })

            -- 高亮选中选项
            widget:SetStyle({
                borderColor = { quizColor[1], quizColor[2], quizColor[3], 200 },
                backgroundColor = { quizColor[1], quizColor[2], quizColor[3], 40 },
                scale = 1.0,
            })

            -- 显示统计加载状态
            statsContainer:SetStyle({ opacity = 1 })
            statsLabel:SetStyle({ text = "加载中..." })

            -- 立即显示下一题按钮
            if _G._quizNextBtn then
                _G._quizNextBtn:SetStyle({ opacity = 1 })
            end
            if _G._quizNextBtnLabel then
                local lblText = hasNextQuestion_ and "下一题" or "查看结果"
                _G._quizNextBtnLabel:SetStyle({ text = lblText })
            end

            -- 向服务端请求当前统计数据（只读，不写入数据库）
            RequestQuestionStats(questionOrigIdx, optionOrigIdx)
        end,

        children = {
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                alignItems = "center",
                gap = 14,
                children = {
                    UI.Panel {
                        width = 36, height = 36,
                        borderRadius = 18,
                        backgroundColor = { quizColor[1], quizColor[2], quizColor[3], 50 },
                        justifyContent = "center",
                        alignItems = "center",
                        children = {
                            UI.Label {
                                text = letter,
                                fontSize = 14,
                                fontColor = quizColor,
                            }
                        }
                    },
                    UI.Label {
                        text = option.text,
                        fontSize = 15,
                        fontColor = COLORS.text,
                        flexGrow = 1,
                        flexShrink = 1,
                        flexBasis = 0,
                        whiteSpace = "normal",
                        lineHeight = 1.4,
                        textAlign = "left",
                    },
                }
            },
            statsContainer,
        }
    }

    -- 保存引用供 HandleOptionStatsResp 使用
    btn._optionOrigIdx = origIdx
    btn._statsBar = statsBar
    btn._statsLabel = statsLabel
    btn._statsContainer = statsContainer

    return btn
end

function BuildQuizPage()
    if not currentSession_ then
        NavigateTo("home")
        return UI.Panel {}
    end

    -- 重置统计状态
    showingStats_ = false
    pendingStats_ = nil
    selectedOptionIndex_ = nil

    local session = currentSession_
    local question = TestEngine.GetCurrentQuestion(session)
    if not question then
        -- 答题完毕，发送结果
        if currentSession_.result then
            PlayComplete()
            SendTestCompleted(currentSession_.result, currentSession_.dimensionScores)
        end
        NavigateTo("result")
        return UI.Panel {}
    end

    local current, total = TestEngine.GetProgress(session)
    local progressPercent = (current - 1) / total
    local quizColor = session.quiz.color or COLORS.accent

    -- 构建选项按钮
    local optionWidgets = {}
    for i, option in ipairs(question.options) do
        table.insert(optionWidgets, BuildOptionButton(option, i, quizColor, question))
    end

    -- "下一题"按钮标签（保存直接引用，避免 FindChild）
    local nextBtnLabel = UI.Label {
        text = "下一题",
        fontSize = 16,
        fontColor = { 20, 20, 40, 255 },
    }

    -- "下一题"按钮（内联，放在底部栏右侧）
    local nextBtn = UI.Panel {
        id = "next_btn",
        width = 120,
        height = 40,
        borderRadius = 20,
        backgroundColor = { quizColor[1], quizColor[2], quizColor[3], 255 },
        justifyContent = "center",
        alignItems = "center",
        transition = "scale 0.15s easeOut, backgroundColor 0.15s easeOut, opacity 0.3s easeOut",
        opacity = 0,
        onPointerEnter = function(event, widget)
            widget:SetStyle({ scale = 1.03 })
        end,
        onPointerLeave = function(event, widget)
            widget:SetStyle({ scale = 1.0 })
        end,
        onClick = function(self)
            PlayClick()
            if hasNextQuestion_ then
                NavigateTo("quiz")
            else
                if currentSession_.result then
                    PlayComplete()
                    SendTestCompleted(currentSession_.result, currentSession_.dimensionScores)
                end
                NavigateTo("result")
            end
        end,
        children = { nextBtnLabel },
    }

    -- 保存引用供统计回调和点击逻辑使用
    _G._quizOptionWidgets = optionWidgets
    _G._quizNextBtn = nextBtn
    _G._quizNextBtnLabel = nextBtnLabel
    _G._quizQuestion = question

    return UI.Panel {
        width = "100%",
        height = "100%",
        backgroundImage = "image/dfti_quiz_bg_20260412144932.png",
        backgroundFit = "cover",
        children = {
            UI.Panel {
                width = "100%",
                height = "100%",
                backgroundColor = { 15, 15, 35, 200 },
                flexDirection = "column",
                children = {
                    -- 顶栏
                    UI.Panel {
                        width = "100%",
                        flexDirection = "row",
                        alignItems = "center",
                        paddingHorizontal = 16,
                        paddingVertical = 12,
                        gap = 12,
                        children = {
                            (function()
                                local lbl = UI.Label {
                                    text = soundEnabled_ and "ON" or "OFF",
                                    fontSize = 10,
                                    fontColor = soundEnabled_ and { 220, 170, 60, 255 } or { 255, 255, 255, 80 },
                                }
                                return UI.Panel {
                                    width = 40, height = 40,
                                    borderRadius = 20,
                                    justifyContent = "center",
                                    alignItems = "center",
                                    onClick = function(self)
                                        PlayClick()
                                        ToggleSound()
                                        lbl:SetStyle({
                                            text = soundEnabled_ and "ON" or "OFF",
                                            fontColor = soundEnabled_ and { 220, 170, 60, 255 } or { 255, 255, 255, 80 },
                                        })
                                    end,
                                    children = { lbl },
                                }
                            end)(),
                            UI.Label {
                                text = current .. " / " .. total,
                                fontSize = 14,
                                fontColor = COLORS.textDim,
                                flexGrow = 1,
                                textAlign = "center",
                            },
                            UI.Button {
                                text = "✕",
                                fontSize = 16,
                                width = 40, height = 40,
                                backgroundColor = { 0, 0, 0, 0 },
                                textColor = COLORS.textDim,
                                borderRadius = 20,
                                onClick = function(self)
                                    PlayClick()
                                    currentSession_ = nil
                                    NavigateTo("home")
                                end,
                            },
                        }
                    },

                    -- 进度条
                    UI.Panel {
                        width = "100%",
                        height = 4,
                        backgroundColor = COLORS.progressBg,
                        children = {
                            UI.Panel {
                                width = tostring(math.floor(progressPercent * 100)) .. "%",
                                height = "100%",
                                backgroundColor = quizColor,
                                transition = "width 0.3s easeOut",
                            }
                        }
                    },

                    -- 题目区域
                    UI.Panel {
                        flexGrow = 3,
                        flexBasis = 0,
                        width = "100%",
                        justifyContent = "center",
                        alignItems = "center",
                        paddingHorizontal = 24,
                        children = {
                            UI.Panel {
                                width = "100%",
                                maxWidth = 440,
                                alignItems = "center",
                                children = {
                                    UI.Label {
                                        text = question.text,
                                        fontSize = 20,
                                        fontColor = COLORS.white,
                                        whiteSpace = "normal",
                                        lineHeight = 1.5,
                                        textAlign = "center",
                                        width = "100%",
                                    },
                                }
                            }
                        }
                    },

                    -- 选项区域
                    UI.Panel {
                        flexGrow = 7,
                        flexBasis = 0,
                        width = "100%",
                        children = {
                            UI.ScrollView {
                                flexGrow = 1,
                                flexShrink = 1,
                                width = "100%",
                                children = {
                                    UI.Panel {
                                        width = "100%",
                                        alignItems = "center",
                                        paddingHorizontal = 20,
                                        paddingTop = 4,
                                        paddingBottom = 12,
                                        children = {
                                            UI.Panel {
                                                width = "100%",
                                                maxWidth = 440,
                                                gap = 12,
                                                children = optionWidgets,
                                            },
                                        },
                                    },
                                },
                            },
                            -- 底部栏：上一题 + 下一题
                            UI.Panel {
                                width = "100%",
                                flexDirection = "row",
                                justifyContent = "space-between",
                                alignItems = "center",
                                paddingHorizontal = 20,
                                paddingVertical = 10,
                                children = {
                                    UI.Button {
                                        text = "上一题",
                                        fontSize = 14,
                                        backgroundColor = current > 1 and { quizColor[1], quizColor[2], quizColor[3], 80 } or { 0, 0, 0, 0 },
                                        textColor = current > 1 and COLORS.white or { 255, 255, 255, 60 },
                                        borderRadius = 8,
                                        paddingHorizontal = 16,
                                        paddingVertical = 8,
                                        onClick = function(self)
                                            if current <= 1 and not showingStats_ then return end
                                            PlayClick()

                                            if showingStats_ then
                                                -- 已选答案后，Answer() 已将 currentIndex 推进到 current+1
                                                -- 先撤销当前题的答案（GoBack: current+1 → current）
                                                if TestEngine.GoBack(currentSession_) then
                                                    if #answerRecords_ > 0 then
                                                        table.remove(answerRecords_)
                                                    end
                                                end
                                                NavigateTo("quiz")
                                            else
                                                -- 未选答案，直接回到上一题
                                                if TestEngine.GoBack(currentSession_) then
                                                    if #answerRecords_ > 0 then
                                                        table.remove(answerRecords_)
                                                    end
                                                    NavigateTo("quiz")
                                                end
                                            end
                                        end,
                                    },
                                    nextBtn,
                                }
                            },
                        }
                    },
                }
            },
            BuildUserIdLabel(),
            BuildVersionLabel(),
        }
    }
end

-- ============================================================================
-- 历史详情页（全屏，与结果页风格一致）
-- ============================================================================

function BuildHistoryDetailPage()
    local record = viewingHistoryRecord_
    local index = viewingHistoryIndex_ or 1
    if not record then
        NavigateTo("home")
        return UI.Panel {}
    end

    local typeCode = record.result or "?"
    local info = TYPE_INFO[typeCode]
    if not info then
        info = { animal = "未知", color = { 156, 163, 175, 255 }, description = "未知类型", traits = {}, operator = "未知" }
    end
    local resultColor = info.color

    -- 时间
    local timeStr = ""
    if record.timestamp then
        timeStr = os.date("%Y-%m-%d %H:%M", record.timestamp)
    end

    -- 特质标签
    local traitWidgets = {}
    for _, trait in ipairs(info.traits or {}) do
        table.insert(traitWidgets, UI.Panel {
            paddingHorizontal = 14,
            paddingVertical = 6,
            backgroundColor = { resultColor[1], resultColor[2], resultColor[3], 35 },
            borderRadius = 16,
            borderWidth = 1,
            borderColor = { resultColor[1], resultColor[2], resultColor[3], 60 },
            children = {
                UI.Label {
                    text = trait,
                    fontSize = 12,
                    fontColor = resultColor,
                }
            }
        })
    end

    -- 维度分数展示
    local dimWidgets = {}
    if record.scores then
        for _, dim in ipairs(DIM_NAMES) do
            local score = record.scores[dim.id]
            if score then
                local maxRange = 5
                local normalized = (score / maxRange + 1) / 2
                normalized = math.max(0.05, math.min(0.95, normalized))
                local percent = math.floor(normalized * 100)

                table.insert(dimWidgets, UI.Panel {
                    width = "100%",
                    gap = 6,
                    children = {
                        UI.Panel {
                            flexDirection = "row",
                            justifyContent = "space-between",
                            width = "100%",
                            children = {
                                UI.Label {
                                    text = dim.nameA,
                                    fontSize = 12,
                                    fontColor = COLORS.textDim,
                                },
                                UI.Label {
                                    text = dim.nameB,
                                    fontSize = 12,
                                    fontColor = COLORS.textDim,
                                },
                            }
                        },
                        UI.Panel {
                            width = "100%",
                            height = 8,
                            borderRadius = 4,
                            backgroundColor = COLORS.progressBg,
                            overflow = "hidden",
                            children = {
                                UI.Panel {
                                    width = percent .. "%",
                                    height = "100%",
                                    borderRadius = 4,
                                    backgroundColor = resultColor,
                                }
                            }
                        },
                    }
                })
            end
        end
    end

    local resultChildren = {
        -- 类型代号
        UI.Label {
            text = typeCode,
            fontSize = 14,
            fontColor = { resultColor[1], resultColor[2], resultColor[3], 180 },
            letterSpacing = 4,
        },
        -- 动物名称
        UI.Label {
            text = info.animal,
            fontSize = 26,
            fontColor = COLORS.white,
        },
        -- 推荐干员
        info.operator and UI.Panel {
            flexDirection = "row",
            alignItems = "center",
            gap = 6,
            paddingHorizontal = 14,
            paddingVertical = 6,
            backgroundColor = { resultColor[1], resultColor[2], resultColor[3], 20 },
            borderRadius = 16,
            children = {
                UI.Label {
                    text = "适配干员",
                    fontSize = 11,
                    fontColor = COLORS.textDim,
                },
                UI.Label {
                    text = info.operator,
                    fontSize = 12,
                    fontColor = resultColor,
                },
            }
        } or nil,
        -- 结果描述
        UI.Label {
            text = info.description or "",
            fontSize = 14,
            fontColor = COLORS.textDim,
            whiteSpace = "normal",
            lineHeight = 1.6,
            textAlign = "center",
            width = "100%",
            marginTop = 4,
        },
    }

    -- 过滤 nil
    local filtered = {}
    for _, child in ipairs(resultChildren) do
        if child then table.insert(filtered, child) end
    end
    resultChildren = filtered

    -- 特质标签区域
    if #traitWidgets > 0 then
        table.insert(resultChildren, UI.Panel {
            flexDirection = "row",
            flexWrap = "wrap",
            justifyContent = "center",
            gap = 8,
            marginTop = 4,
            children = traitWidgets,
        })
    end

    -- 维度得分区域
    if #dimWidgets > 0 then
        table.insert(resultChildren, UI.Panel {
            width = "100%",
            gap = 12,
            marginTop = 8,
            padding = 16,
            backgroundColor = { 20, 20, 45, 200 },
            borderRadius = 12,
            children = dimWidgets,
        })
    end

    -- 返回按钮（只有一个）
    table.insert(resultChildren, UI.Panel {
        flexDirection = "row",
        gap = 12,
        marginTop = 8,
        children = {
            UI.Button {
                text = "返回",
                fontSize = 14,
                height = 44,
                paddingHorizontal = 32,
                backgroundColor = resultColor,
                borderRadius = 22,
                textColor = COLORS.white,
                onClick = function(self)
                    PlayClick()
                    viewingHistoryRecord_ = nil
                    viewingHistoryIndex_ = nil
                    NavigateTo("home")
                    -- 延迟重新打开历史弹窗
                    OpenHistoryModal()
                end,
            },
        }
    })

    return UI.Panel {
        width = "100%",
        height = "100%",
        backgroundImage = "image/dfti_home_banner_20260412132653.png",
        backgroundFit = "cover",
        children = {
            UI.Panel {
                width = "100%",
                height = "100%",
                backgroundColor = { 10, 10, 28, 200 },
                children = {
                    UI.ScrollView {
                        width = "100%",
                        height = "100%",
                        flexGrow = 1,
                        flexBasis = 0,
                        children = {
                            UI.Panel {
                                width = "100%",
                                alignItems = "center",
                                paddingHorizontal = 8,
                                paddingVertical = 32,
                                children = {
                                    UI.Panel {
                                        width = "100%",
                                        alignItems = "center",
                                        gap = 12,
                                        children = resultChildren,
                                    }
                                }
                            }
                        }
                    }
                }
            },
            BuildSoundToggle(),
            BuildUserIdLabel(),
            BuildVersionLabel(),
        }
    }
end

-- ============================================================================
-- 结果页
-- ============================================================================

function BuildResultPage()
    if not currentSession_ or not currentSession_.result then
        NavigateTo("home")
        return UI.Panel {}
    end

    local result = currentSession_.result
    local resultColor = result.color or COLORS.accent
    local quiz = currentSession_.quiz

    -- 特质标签
    local traitWidgets = {}
    for _, trait in ipairs(result.traits or {}) do
        table.insert(traitWidgets, UI.Panel {
            paddingHorizontal = 14,
            paddingVertical = 6,
            backgroundColor = { resultColor[1], resultColor[2], resultColor[3], 35 },
            borderRadius = 16,
            borderWidth = 1,
            borderColor = { resultColor[1], resultColor[2], resultColor[3], 60 },
            children = {
                UI.Label {
                    text = trait,
                    fontSize = 12,
                    fontColor = resultColor,
                }
            }
        })
    end

    -- 维度分数展示
    local dimWidgets = {}
    if quiz.dimensions and currentSession_.dimensionScores then
        for _, dim in ipairs(quiz.dimensions) do
            local score = currentSession_.dimensionScores[dim.id] or 0
            table.insert(dimWidgets, BuildDimensionBar(dim, score))
        end
    end

    local resultChildren = {
        -- 类型代号
        UI.Label {
            text = result.type or "?",
            fontSize = 14,
            fontColor = { resultColor[1], resultColor[2], resultColor[3], 180 },
            letterSpacing = 4,
        },
        -- 动物名称
        UI.Label {
            text = result.animal or "未知",
            fontSize = 26,
            fontColor = COLORS.white,
        },
        -- 推荐干员
        result.operator and UI.Panel {
            flexDirection = "row",
            alignItems = "center",
            gap = 6,
            paddingHorizontal = 14,
            paddingVertical = 6,
            backgroundColor = { resultColor[1], resultColor[2], resultColor[3], 20 },
            borderRadius = 16,
            children = {
                UI.Label {
                    text = "适配干员",
                    fontSize = 11,
                    fontColor = COLORS.textDim,
                },
                UI.Label {
                    text = result.operator,
                    fontSize = 12,
                    fontColor = resultColor,
                },
            }
        } or nil,
        -- 结果描述
        UI.Label {
            text = result.description or "",
            fontSize = 14,
            fontColor = COLORS.textDim,
            whiteSpace = "normal",
            lineHeight = 1.6,
            textAlign = "center",
            width = "100%",
            marginTop = 4,
        },
    }

    -- 过滤 nil
    local filtered = {}
    for _, child in ipairs(resultChildren) do
        if child then table.insert(filtered, child) end
    end
    resultChildren = filtered

    -- 特质标签区域
    if #traitWidgets > 0 then
        table.insert(resultChildren, UI.Panel {
            flexDirection = "row",
            flexWrap = "wrap",
            justifyContent = "center",
            gap = 8,
            marginTop = 4,
            children = traitWidgets,
        })
    end

    -- 统计展示区域（"X人和你一样"）
    local resultStatsLabel = UI.Label {
        text = "正在加载统计数据...",
        fontSize = 13,
        fontColor = { 220, 170, 60, 200 },
        textAlign = "center",
        width = "100%",
        whiteSpace = "normal",
    }

    local statsPanel = UI.Panel {
        id = "result_stats_panel",
        width = "100%",
        paddingVertical = 12,
        paddingHorizontal = 16,
        backgroundColor = { 220, 170, 60, 15 },
        borderRadius = 12,
        borderWidth = 1,
        borderColor = { 220, 170, 60, 40 },
        marginTop = 8,
        alignItems = "center",
        gap = 4,
        children = {
            resultStatsLabel,
        },
    }
    -- 保存引用供回调更新
    _G._resultStatsPanel = statsPanel
    _G._resultStatsLabel = resultStatsLabel

    table.insert(resultChildren, statsPanel)

    -- 如果已经有统计数据（快速回复），立即显示
    if resultStats_ then
        local pct = resultStats_.total > 0
            and math.floor(resultStats_.count / resultStats_.total * 100)
            or 0
        local animalName = result.animal or result.type or "?"
        -- 延迟一帧后更新（确保 widget 已挂载）
    end

    -- 维度得分区域
    if #dimWidgets > 0 then
        table.insert(resultChildren, UI.Panel {
            width = "100%",
            gap = 12,
            marginTop = 8,
            padding = 16,
            backgroundColor = { 20, 20, 45, 200 },
            borderRadius = 12,
            children = dimWidgets,
        })
    end

    -- 操作按钮
    table.insert(resultChildren, UI.Panel {
        flexDirection = "row",
        gap = 12,
        marginTop = 8,
        children = {
            UI.Button {
                text = "再测一次",
                fontSize = 14,
                height = 44,
                paddingHorizontal = 24,
                backgroundColor = resultColor,
                borderRadius = 22,
                textColor = COLORS.white,
                onClick = function(self)
                    PlayClick()
                    currentSession_ = TestEngine.CreateSession(currentSession_.quiz)
                    answerRecords_ = {}
                    resultStats_ = nil
                    NavigateTo("quiz")
                end,
            },
            UI.Button {
                text = "返回首页",
                fontSize = 14,
                height = 44,
                paddingHorizontal = 24,
                backgroundColor = { 0, 0, 0, 0 },
                borderRadius = 22,
                borderWidth = 1,
                borderColor = COLORS.border,
                textColor = COLORS.textDim,
                onClick = function(self)
                    PlayClick()
                    currentSession_ = nil
                    NavigateTo("home")
                end,
            },
        }
    })

    return UI.Panel {
        width = "100%",
        height = "100%",
        backgroundImage = "image/dfti_home_banner_20260412132653.png",
        backgroundFit = "cover",
        children = {
            UI.Panel {
                width = "100%",
                height = "100%",
                backgroundColor = { 10, 10, 28, 200 },
                children = {
                    UI.ScrollView {
                        width = "100%",
                        height = "100%",
                        flexGrow = 1,
                        flexBasis = 0,
                        children = {
                            UI.Panel {
                                width = "100%",
                                alignItems = "center",
                                paddingHorizontal = 8,
                                paddingVertical = 32,
                                children = {
                                    UI.Panel {
                                        width = "100%",
                                        alignItems = "center",
                                        gap = 12,
                                        children = resultChildren,
                                    }
                                }
                            }
                        }
                    }
                }
            },
            BuildSoundToggle(),
            BuildUserIdLabel(),
            BuildVersionLabel(),
        }
    }
end

--- 构建维度得分条
function BuildDimensionBar(dim, score)
    local maxRange = 5
    local normalized = (score / maxRange + 1) / 2
    normalized = math.max(0.05, math.min(0.95, normalized))
    local percent = math.floor(normalized * 100)

    return UI.Panel {
        width = "100%",
        gap = 6,
        children = {
            UI.Panel {
                flexDirection = "row",
                justifyContent = "space-between",
                width = "100%",
                children = {
                    UI.Label {
                        text = dim.nameA,
                        fontSize = 12,
                        fontColor = COLORS.textDim,
                    },
                    UI.Label {
                        text = dim.nameB,
                        fontSize = 12,
                        fontColor = COLORS.textDim,
                    },
                }
            },
            UI.Panel {
                width = "100%",
                height = 8,
                borderRadius = 4,
                backgroundColor = COLORS.progressBg,
                overflow = "hidden",
                children = {
                    UI.Panel {
                        width = percent .. "%",
                        height = "100%",
                        borderRadius = 4,
                        backgroundColor = COLORS.accent,
                    }
                }
            },
        }
    }
end

-- ============================================================================
-- 网络事件处理
-- ============================================================================

--- 收到服务端下发的用户信息
function HandleClientInfo(eventType, eventData)
    local ok, uid = pcall(function()
        return eventData["UserId"]:GetString()
    end)
    if ok and uid then
        myUserId_ = uid
        isAdmin_ = (tonumber(uid) == ADMIN_USER_ID)
        print("[Client] My userId=" .. myUserId_ .. " isAdmin=" .. tostring(isAdmin_))
    else
        print("[Client] HandleClientInfo error: " .. tostring(uid))
    end
end

--- 收到选题统计响应
function HandleOptionStatsResp(eventType, eventData)
    local dataJson = eventData["Data"]:GetString()
    local ok, data = pcall(cjson.decode, dataJson)
    if not ok or not data then
        print("[Client] OptionStatsResp: invalid data")
        return
    end

    print(string.format("[Client] OptionStatsResp q=%s total=%s",
        tostring(data.questionId), tostring(data.total)))

    -- 只在当前页是答题页且正在展示统计状态时更新 UI
    if currentPage_ ~= "quiz" or not showingStats_ then
        return
    end

    local widgets = _G._quizOptionWidgets
    local nextBtnWidget = _G._quizNextBtn
    if not widgets then return end

    local totalCount = data.total or 0

    -- 更新每个选项的统计条和文字
    for i, w in ipairs(widgets) do
        local origIdx = w._optionOrigIdx
        local count = 0
        if data.counts and data.counts[tostring(origIdx)] then
            count = data.counts[tostring(origIdx)]
        end
        local pct = totalCount > 0 and math.floor(count / totalCount * 100) or 0

        -- 显示统计容器
        if w._statsContainer then
            w._statsContainer:SetStyle({ opacity = 1 })
        end
        -- 更新统计条宽度
        if w._statsBar then
            w._statsBar:SetStyle({ width = pct .. "%" })
        end
        -- 更新统计文字（选中项加"已选"前缀）
        if w._statsLabel then
            local prefix = (i == selectedOptionIndex_) and "已选 · " or ""
            w._statsLabel:SetStyle({
                text = prefix .. count .. "人 · " .. pct .. "%",
            })
        end
    end
end

--- 收到结果统计响应
function HandleResultStatsResp(eventType, eventData)
    local dataJson = eventData["Data"]:GetString()
    local ok, data = pcall(cjson.decode, dataJson)
    if not ok or not data then
        print("[Client] ResultStatsResp: invalid data")
        return
    end

    resultStats_ = data
    print(string.format("[Client] ResultStatsResp type=%s count=%d total=%d",
        tostring(data.typeCode), data.count or 0, data.total or 0))

    -- 更新结果页统计面板
    if currentPage_ == "result" and _G._resultStatsPanel then
        local pct = data.total > 0
            and math.floor(data.count / data.total * 100)
            or 0
        local animalName = ""
        if currentSession_ and currentSession_.result then
            animalName = currentSession_.result.animal or currentSession_.result.type or "?"
        end

        local statsText = string.format(
            "共 %d 人完成测试，%d 人和你一样是「%s」(%d%%)",
            data.total, data.count, animalName, pct
        )

        if _G._resultStatsLabel then
            _G._resultStatsLabel:SetStyle({
                text = statsText,
                fontColor = { 220, 170, 60, 255 },
            })
        end
    end
end

--- 连接成功后发送 ClientReady
function HandleServerConnected(eventType, eventData)
    print("[Client] Connected to server, sending ClientReady")
    local serverConn = network.serverConnection
    if serverConn then
        local data = VariantMap()
        serverConn:SendRemoteEvent(EVENTS.CLIENT_READY, true, data)
    end
end

-- ============================================================================
-- 生命周期
-- ============================================================================

function Client.Start()
    graphics.windowTitle = "人格测试"

    -- 创建场景
    scene_ = Scene()
    scene_:CreateComponent("Octree")

    -- 初始化 UI
    UI.Init({
        fonts = {
            { family = "sans", weights = {
                normal = "Fonts/MiSans-Regular.ttf",
            } }
        },
        scale = UI.Scale.DEFAULT,
    })

    -- 管理员身份在收到 CLIENT_INFO 后判断

    -- 初始化音频
    InitAudio()

    -- 加载测试集
    LoadQuizzes()

    -- 注册网络事件
    Shared.RegisterEvents()

    -- 订阅网络事件回调
    SubscribeToEvent(EVENTS.CLIENT_INFO, "HandleClientInfo")
    SubscribeToEvent(EVENTS.OPTION_STATS_RESP, "HandleOptionStatsResp")
    SubscribeToEvent(EVENTS.RESULT_STATS_RESP, "HandleResultStatsResp")
    SubscribeToEvent(EVENTS.HISTORY_RESP, "HandleHistoryResp")
    SubscribeToEvent(EVENTS.ALL_RESULTS_RESP, "HandleAllResultsResp")
    SubscribeToEvent("ServerConnected", "HandleServerConnected")

    -- 如果已经连接到服务器，立即发送 ClientReady
    if network.serverConnection then
        local data = VariantMap()
        network.serverConnection:SendRemoteEvent(EVENTS.CLIENT_READY, true, data)
        print("[Client] Already connected, sent ClientReady")
    end

    -- 显示首页
    NavigateTo("home")

    -- 订阅更新事件
    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("KeyDown", "HandleKeyDown")

    print("=== DFTI 客户端已启动 ===")
end

function Client.Stop()
    UI.Shutdown()
end

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()

    if fadeIn_ < 1 then
        fadeIn_ = math.min(1, fadeIn_ + dt * fadeSpeed_)
    end
end

---@param eventType string
---@param eventData KeyDownEventData
function HandleKeyDown(eventType, eventData)
    local key = eventData["Key"]:GetInt()

    if key == KEY_ESCAPE then
        if currentPage_ == "history_detail" then
            viewingHistoryRecord_ = nil
            viewingHistoryIndex_ = nil
            NavigateTo("home")
            OpenHistoryModal()
        elseif currentPage_ == "quiz" or currentPage_ == "result" then
            currentSession_ = nil
            NavigateTo("home")
        end
    elseif key == KEY_F8 and isAdmin_ then
        OpenViewQuestionsModal()
    end
end

return Client
