-- ============================================================================
-- TestEngine.lua - 人格测试引擎
-- 负责：加载测试集、计算分数、匹配结果类型
-- ============================================================================

---@class TestEngine
local TestEngine = {}

-- ============================================================================
-- 测试集数据格式规范 (Quiz Data Format Specification)
-- ============================================================================
--[[
每个测试集是一个 Lua table，格式如下：

{
    id = "mbti",                        -- 唯一标识
    title = "MBTI 性格测试",            -- 显示标题
    description = "探索你的性格类型",    -- 简短描述
    icon = "🧠",                        -- 图标（emoji）
    color = { 59, 130, 246, 255 },      -- 主题色 RGBA

    -- 维度定义（用于计分）
    dimensions = {
        { id = "E_I", nameA = "外向 E", nameB = "内向 I" },
        { id = "S_N", nameA = "感觉 S", nameB = "直觉 N" },
    },

    -- 题目列表
    questions = {
        {
            text = "在派对上你通常...",
            options = {
                { text = "主动和很多人交流", scores = { E_I = 1 } },
                { text = "和少数熟人深聊",   scores = { E_I = -1 } },
            }
        },
    },

    -- 结果计算函数（接收 dimensionScores table，返回结果 table）
    calculateResult = function(scores)
        return {
            type = "ENFP",
            title = "竞选者",
            description = "热情、有创意的自由精神...",
            traits = { "热情洋溢", "富有想象力", "善于交际" },
            color = { 255, 193, 7, 255 },
        }
    end,
}
]]

-- ============================================================================
-- 引擎核心逻辑
-- ============================================================================

--- Fisher-Yates 洗牌算法（原地打乱）
---@param t table
local function Shuffle(t)
    for i = #t, 2, -1 do
        local j = math.random(1, i)
        t[i], t[j] = t[j], t[i]
    end
end

--- 深拷贝题目列表（避免修改原始数据）并打乱顺序
---@param questions table
---@return table shuffled
local function ShuffleQuestions(questions)
    -- 浅拷贝题目列表
    local list = {}
    for i, q in ipairs(questions) do
        -- 拷贝每道题，并打乱选项顺序
        local optionsCopy = {}
        for _, opt in ipairs(q.options) do
            table.insert(optionsCopy, opt)
        end
        Shuffle(optionsCopy)
        table.insert(list, {
            text = q.text,
            options = optionsCopy,
        })
    end
    -- 打乱题目顺序
    Shuffle(list)
    return list
end

--- 创建一个新的测试会话
---@param quizData table 测试集数据
---@return table session 测试会话
function TestEngine.CreateSession(quizData)
    -- 打乱题目和选项顺序（不修改原始数据）
    local shuffledQuestions = ShuffleQuestions(quizData.questions)

    -- 创建一份带打乱题目的 quiz 副本
    local shuffledQuiz = {
        id = quizData.id,
        title = quizData.title,
        description = quizData.description,
        icon = quizData.icon,
        color = quizData.color,
        dimensions = quizData.dimensions,
        questions = shuffledQuestions,
        calculateResult = quizData.calculateResult,
    }

    local session = {
        quiz = shuffledQuiz,
        currentIndex = 1,
        answers = {},            -- { [questionIndex] = optionIndex }
        dimensionScores = {},    -- { [dimensionId] = number }
        finished = false,
        result = nil,
    }

    -- 初始化维度分数
    if quizData.dimensions then
        for _, dim in ipairs(quizData.dimensions) do
            session.dimensionScores[dim.id] = 0
        end
    end

    print("[TestEngine] Session created for: " .. quizData.title .. " (shuffled)")
    print("[TestEngine] Total questions: " .. #shuffledQuestions)
    return session
end

--- 获取当前题目
---@param session table
---@return table|nil question 当前题目，若已结束则返回 nil
function TestEngine.GetCurrentQuestion(session)
    if session.currentIndex > #session.quiz.questions then
        return nil
    end
    return session.quiz.questions[session.currentIndex]
end

--- 回答当前题目
---@param session table
---@param optionIndex number 选项索引（1-based）
---@return boolean hasNext 是否还有下一题
function TestEngine.Answer(session, optionIndex)
    local question = TestEngine.GetCurrentQuestion(session)
    if not question then
        return false
    end

    local option = question.options[optionIndex]
    if not option then
        print("[TestEngine] Warning: invalid option index " .. optionIndex)
        return false
    end

    -- 记录答案
    session.answers[session.currentIndex] = optionIndex

    -- 累加维度分数
    if option.scores then
        for dimId, score in pairs(option.scores) do
            session.dimensionScores[dimId] = (session.dimensionScores[dimId] or 0) + score
        end
    end

    print(string.format("[TestEngine] Q%d answered option %d", session.currentIndex, optionIndex))

    -- 前进到下一题
    session.currentIndex = session.currentIndex + 1

    -- 检查是否完成
    if session.currentIndex > #session.quiz.questions then
        session.finished = true
        session.result = TestEngine.CalculateResult(session)
        print("[TestEngine] Quiz finished! Result: " .. (session.result.type or "N/A"))
        return false
    end

    return true
end

--- 回退到上一题
---@param session table
---@return boolean success 是否成功回退
function TestEngine.GoBack(session)
    if session.currentIndex <= 1 then
        return false
    end

    -- 撤销上一题的分数
    local prevIndex = session.currentIndex - 1
    local prevOptionIndex = session.answers[prevIndex]
    if prevOptionIndex then
        local prevQuestion = session.quiz.questions[prevIndex]
        local prevOption = prevQuestion.options[prevOptionIndex]
        if prevOption and prevOption.scores then
            for dimId, score in pairs(prevOption.scores) do
                session.dimensionScores[dimId] = (session.dimensionScores[dimId] or 0) - score
            end
        end
        session.answers[prevIndex] = nil
    end

    session.currentIndex = prevIndex
    session.finished = false
    session.result = nil
    print("[TestEngine] Went back to Q" .. prevIndex)
    return true
end

--- 计算最终结果
---@param session table
---@return table result 结果数据
function TestEngine.CalculateResult(session)
    if session.quiz.calculateResult then
        return session.quiz.calculateResult(session.dimensionScores)
    end

    -- 默认结果（如果测试集没有自定义计算函数）
    return {
        type = "未知",
        title = "测试完成",
        description = "感谢你完成测试！",
        traits = {},
        color = { 100, 100, 100, 255 },
    }
end

--- 获取进度信息
---@param session table
---@return number current, number total
function TestEngine.GetProgress(session)
    local total = #session.quiz.questions
    local current = math.min(session.currentIndex, total)
    return current, total
end

--- 获取进度百分比
---@param session table
---@return number percent 0.0 ~ 1.0
function TestEngine.GetProgressPercent(session)
    local current, total = TestEngine.GetProgress(session)
    if total == 0 then return 0 end
    return (current - 1) / total
end

return TestEngine
