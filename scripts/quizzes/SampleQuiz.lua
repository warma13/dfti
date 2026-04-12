-- ============================================================================
-- SampleQuiz.lua - 示例测试集（占位用，展示数据格式）
-- 只有 3 道题，用于验证框架功能
-- ============================================================================

local SampleQuiz = {
    id = "sample",
    title = "性格倾向小测试",
    description = "3 道快速小题，体验测试流程",
    icon = "✨",
    color = { 139, 92, 246, 255 },   -- 紫色

    dimensions = {
        { id = "A_B", nameA = "外向型 A", nameB = "内省型 B" },
    },

    questions = {
        {
            text = "周末你更想做什么？",
            options = {
                { text = "约朋友出去聚餐、逛街",   scores = { A_B = 1 } },
                { text = "待在家里看书或看电影",     scores = { A_B = -1 } },
                { text = "去一个没去过的地方探险",   scores = { A_B = 1 } },
                { text = "一个人安静地画画或写东西", scores = { A_B = -1 } },
            }
        },
        {
            text = "遇到难题时你会怎么做？",
            options = {
                { text = "找朋友一起讨论",       scores = { A_B = 1 } },
                { text = "自己先思考一阵子",     scores = { A_B = -1 } },
                { text = "上网搜索各种方案",     scores = { A_B = 0 } },
                { text = "先放一放，散步想想",   scores = { A_B = -1 } },
            }
        },
        {
            text = "理想的工作环境是？",
            options = {
                { text = "热闹的开放式办公室",   scores = { A_B = 1 } },
                { text = "安静的独立工作间",     scores = { A_B = -1 } },
                { text = "灵活的远程办公",       scores = { A_B = 0 } },
                { text = "咖啡厅等公共空间",     scores = { A_B = 1 } },
            }
        },
    },

    calculateResult = function(scores)
        local ab = scores.A_B or 0
        if ab > 0 then
            return {
                type = "A",
                title = "社交达人",
                description = "你是一个喜欢与人交流、充满活力的人。你从社交活动中获取能量，善于团队合作。",
                traits = { "热情开朗", "善于沟通", "行动力强" },
                color = { 251, 146, 60, 255 },
            }
        elseif ab < 0 then
            return {
                type = "B",
                title = "深思者",
                description = "你是一个喜欢独处思考、内心丰富的人。你善于深度分析问题，拥有敏锐的洞察力。",
                traits = { "思维缜密", "创造力强", "善于观察" },
                color = { 99, 102, 241, 255 },
            }
        else
            return {
                type = "A/B",
                title = "平衡者",
                description = "你在社交与独处之间保持了很好的平衡。你能灵活切换不同的社交模式。",
                traits = { "适应力强", "情商高", "灵活变通" },
                color = { 34, 197, 94, 255 },
            }
        end
    end,
}

return SampleQuiz
