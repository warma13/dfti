-- ============================================================================
-- Settings.lua - DFTI 网络配置
-- ============================================================================

local Settings = {}

-- 系统用户 ID（用于存储全局统计数据，Server.Start 中从 SERVER_PLAYER_AUTH_INFOS 赋值）
Settings.SYSTEM_UID = nil

-- 管理员用户 ID 列表
Settings.ADMIN_UIDS = {
    [413248871] = true,
}

-- serverCloud 存储键
Settings.Keys = {
    QUESTION_STATS    = "question_stats",    -- 全局选题统计
    RESULT_STATS      = "result_stats",      -- 全局结果类型统计
    TEST_HISTORY      = "test_history",      -- 玩家测试历史（per-user）
    USER_CONTRIBUTION = "user_contribution", -- 用户上次答题贡献（用于去重）
    USER_QUESTIONS    = "user_questions",    -- 用户上传的题目列表（per-user）
    ALL_QUESTIONS     = "all_questions",     -- 全局题目汇总（存于 SYSTEM_UID 下）
    ALL_FEEDBACKS     = "all_feedbacks",     -- 全局反馈汇总（存于 SYSTEM_UID 下）
}

-- 最大历史记录数
Settings.MAX_HISTORY = 10

-- 网络事件
Settings.EVENTS = {
    CLIENT_READY       = "ClientReady",
    OPTION_SELECTED    = "OptionSelected",
    OPTION_STATS_RESP  = "OptionStatsResp",
    TEST_COMPLETED     = "TestCompleted",
    RESULT_STATS_RESP  = "ResultStatsResp",
    CLIENT_INFO        = "ClientInfo",
    REQUEST_HISTORY    = "RequestHistory",
    HISTORY_RESP       = "HistoryResp",
    REQUEST_ALL_RESULTS = "RequestAllResults",
    ALL_RESULTS_RESP    = "AllResultsResp",
    UPLOAD_QUESTION     = "UploadQuestion",
    UPLOAD_QUESTION_RESP = "UploadQuestionResp",
    REQUEST_USER_QUESTIONS = "RequestUserQuestions",
    USER_QUESTIONS_RESP    = "UserQuestionsResp",
    REQUEST_ALL_QUESTIONS  = "RequestAllQuestions",
    ALL_QUESTIONS_RESP     = "AllQuestionsResp",
    SUBMIT_FEEDBACK        = "SubmitFeedback",
    SUBMIT_FEEDBACK_RESP   = "SubmitFeedbackResp",
    REQUEST_ALL_FEEDBACKS  = "RequestAllFeedbacks",
    ALL_FEEDBACKS_RESP     = "AllFeedbacksResp",
}

return Settings
