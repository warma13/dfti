-- ============================================================================
-- main.lua - 人格测试游戏主程序
-- 基于 scaffold-2d.lua
-- 页面：首页（选择测试集）→ 答题页 → 结果页
-- ============================================================================

local UI = require("urhox-libs/UI")
local TestEngine = require("scripts.TestEngine")

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

-- ============================================================================
-- 测试集注册
-- ============================================================================

--- 注册一个测试集
---@param quizData table 测试集数据（见 TestEngine.lua 中的格式规范）
local function RegisterQuiz(quizData)
    table.insert(quizRegistry_, quizData)
    print("[Main] Registered quiz: " .. quizData.title)
end

--- 加载所有测试集
local function LoadQuizzes()
    -- 加载 DFTI 三角洲行动人格测试
    local dfti = require("scripts.quizzes.DFTIQuiz")
    RegisterQuiz(dfti)

    -- [扩展点] 在此处注册更多测试集：
    -- local mbti = require("scripts.quizzes.MBTIQuiz")
    -- RegisterQuiz(mbti)

    print("[Main] Total quizzes registered: " .. #quizRegistry_)
end

-- ============================================================================
-- 音效控制
-- ============================================================================

--- 初始化音频系统
local function InitAudio()
    -- BGM
    local bgm = cache:GetResource("Sound", "audio/music_1776005111942.ogg")
    if bgm then
        bgm.looped = true
        bgmNode_ = scene_:CreateChild("BGM")
        bgmSource_ = bgmNode_:CreateComponent("SoundSource")
        bgmSource_.soundType = "Music"
        bgmSource_.gain = 0.35
        bgmSource_:Play(bgm)
        print("[Audio] BGM started")
    end

    -- 音效（预加载）
    clickSound_ = cache:GetResource("Sound", "audio/sfx/click.ogg")
    completeSound_ = cache:GetResource("Sound", "audio/sfx/quiz_complete.ogg")
    sfxNode_ = scene_:CreateChild("SFX")
    print("[Audio] Sound effects loaded")
end

--- 播放点击音效
local function PlayClick()
    if not soundEnabled_ or not clickSound_ or not sfxNode_ then return end
    local src = sfxNode_:CreateComponent("SoundSource")
    src.soundType = "Effect"
    src.gain = 0.6
    src.autoRemoveMode = REMOVE_COMPONENT
    src:Play(clickSound_)
end

--- 播放答题完成音效
local function PlayComplete()
    if not soundEnabled_ or not completeSound_ or not sfxNode_ then return end
    local src = sfxNode_:CreateComponent("SoundSource")
    src.soundType = "Effect"
    src.gain = 0.7
    src.autoRemoveMode = REMOVE_COMPONENT
    src:Play(completeSound_)
end

--- 切换音效开关
local function ToggleSound()
    soundEnabled_ = not soundEnabled_
    if bgmSource_ then
        bgmSource_.gain = soundEnabled_ and 0.35 or 0.0
    end
    print("[Audio] Sound " .. (soundEnabled_ and "ON" or "OFF"))
end

-- ============================================================================
-- 页面构建函数
-- ============================================================================

--- 切换页面（销毁旧 UI，创建新 UI）
local function NavigateTo(page)
    currentPage_ = page
    fadeIn_ = 0  -- 重置淡入动画

    local builders = {
        home = "BuildHomePage",
        quiz = "BuildQuizPage",
        result = "BuildResultPage",
    }

    local builderName = builders[page]
    if not builderName then
        print("[Main] Unknown page: " .. page)
        return
    end

    -- 构建新页面
    local root = _G[builderName]()
    UI.SetRoot(root, true)
    uiRoot_ = root

    print("[Main] Navigated to: " .. page)
end

-- ============================================================================
-- 首页
-- ============================================================================

--- 构建音效开关按钮（右上角悬浮）
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

    return UI.Panel {
        width = "100%",
        height = "100%",
        backgroundImage = "image/dfti_home_banner_20260412132653.png",
        backgroundFit = "cover",
        children = {
            -- 全屏暗色渐变遮罩（上方透明，下方深色）
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
                    -- 标题区域
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
                    -- 开始按钮
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
                    -- 题数提示
                    quiz and UI.Label {
                        text = #quiz.questions .. " 道题  ·  约 3 分钟",
                        fontSize = 11,
                        fontColor = { 255, 255, 255, 80 },
                        marginTop = 8,
                    } or nil,
                },
            },
            -- 音效开关（右上角悬浮）
            BuildSoundToggle(),
        }
    }
end

-- ============================================================================
-- 答题页
-- ============================================================================

function BuildQuizPage()
    if not currentSession_ then
        NavigateTo("home")
        return UI.Panel {}
    end

    local session = currentSession_
    local question = TestEngine.GetCurrentQuestion(session)
    if not question then
        NavigateTo("result")
        return UI.Panel {}
    end

    local current, total = TestEngine.GetProgress(session)
    local progressPercent = (current - 1) / total
    local quizColor = session.quiz.color or COLORS.accent

    -- 构建选项按钮
    local optionWidgets = {}
    for i, option in ipairs(question.options) do
        table.insert(optionWidgets, BuildOptionButton(option, i, quizColor))
    end

    return UI.Panel {
        width = "100%",
        height = "100%",
        backgroundImage = "image/dfti_quiz_bg_20260412144932.png",
        backgroundFit = "cover",
        children = {
            -- 暗色半透明遮罩
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
                    -- 左侧音效开关
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
                    -- 进度文字
                    UI.Label {
                        text = current .. " / " .. total,
                        fontSize = 14,
                        fontColor = COLORS.textDim,
                        flexGrow = 1,
                        textAlign = "center",
                    },
                    -- 退出按钮
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

            -- 题目文本区域（占比40%，垂直居中）
            UI.Panel {
                flexGrow = 4,
                flexBasis = 0,
                width = "100%",
                justifyContent = "center",
                alignItems = "center",
                paddingHorizontal = 20,
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

            -- 选项列表（占比50%）
            UI.Panel {
                flexGrow = 5,
                flexBasis = 0,
                width = "100%",
                alignItems = "center",
                paddingHorizontal = 20,
                paddingTop = 12,
                children = {
                    UI.Panel {
                        width = "100%",
                        maxWidth = 440,
                        flexGrow = 1,
                        gap = 12,
                        children = optionWidgets,
                    },
                }
            },

            -- 底部返回区域（占比10%）
            UI.Panel {
                flexGrow = 1,
                flexBasis = 0,
                width = "100%",
                paddingHorizontal = 20,
                alignItems = "flex-start",
                justifyContent = "center",
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
                            PlayClick()
                            if TestEngine.GoBack(currentSession_) then
                                NavigateTo("quiz")
                            end
                        end,
                    },
                }
            },
        }
    },  -- 遮罩 Panel 结束
        }
    }
end

--- 构建单个选项按钮
function BuildOptionButton(option, index, quizColor)
    local letters = { "A", "B", "C", "D", "E", "F" }
    local letter = letters[index] or tostring(index)

    return UI.Panel {
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        justifyContent = "center",
        alignItems = "center",
        padding = 16,
        backgroundColor = COLORS.card,
        borderRadius = 12,
        borderWidth = 1,
        borderColor = COLORS.border,
        transition = "scale 0.15s easeOut, backgroundColor 0.15s easeOut, borderColor 0.15s easeOut",

        onPointerEnter = function(event, widget)
            widget:SetStyle({
                scale = 1.02,
                backgroundColor = COLORS.cardLight,
                borderColor = { quizColor[1], quizColor[2], quizColor[3], 120 },
            })
        end,
        onPointerLeave = function(event, widget)
            widget:SetStyle({
                scale = 1.0,
                backgroundColor = COLORS.card,
                borderColor = COLORS.border,
            })
        end,

        onClick = function(self)
            local hasNext = TestEngine.Answer(currentSession_, index)
            if hasNext then
                PlayClick()
                NavigateTo("quiz")
            else
                PlayComplete()
                NavigateTo("result")
            end
        end,

        children = {
            -- 内层行容器，垂直居中
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                alignItems = "center",
                gap = 14,
                children = {
                    -- 字母标识
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
                    -- 选项文本
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

        -- 推荐干员（如果有）
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

    -- 过滤掉 nil（operator 可能不存在）
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
            -- 半透明暗色遮罩
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
            -- 音效开关（右上角悬浮）
            BuildSoundToggle(),
        }
    }
end

--- 构建维度得分条
function BuildDimensionBar(dim, score)
    -- score 可正可负，正值偏向 nameA，负值偏向 nameB
    -- 将 score 映射到 0~1 范围显示
    local maxRange = 5  -- 假设最大绝对分数
    local normalized = (score / maxRange + 1) / 2  -- 0~1
    normalized = math.max(0.05, math.min(0.95, normalized))
    local percent = math.floor(normalized * 100)

    return UI.Panel {
        width = "100%",
        gap = 6,
        children = {
            -- 标签行
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
            -- 进度条
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
-- 生命周期
-- ============================================================================

function Start()
    graphics.windowTitle = "人格测试"

    -- 创建场景（用于挂载音频组件）
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

    -- 初始化音频
    InitAudio()

    -- 加载测试集
    LoadQuizzes()

    -- 显示首页
    NavigateTo("home")

    -- 订阅事件
    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("KeyDown", "HandleKeyDown")

    print("=== 人格测试游戏已启动 ===")
end

function Stop()
    UI.Shutdown()
end

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()

    -- 淡入动画
    if fadeIn_ < 1 then
        fadeIn_ = math.min(1, fadeIn_ + dt * fadeSpeed_)
    end
end

---@param eventType string
---@param eventData KeyDownEventData
function HandleKeyDown(eventType, eventData)
    local key = eventData["Key"]:GetInt()

    if key == KEY_ESCAPE then
        if currentPage_ == "quiz" or currentPage_ == "result" then
            currentSession_ = nil
            NavigateTo("home")
        end
    end
end
