-- ============================================================================
-- Settings.lua - DFTI 网络配置
-- ============================================================================

local Settings = {}

-- 系统用户 ID（用于存储全局统计数据，Server.Start 中从 SERVER_PLAYER_AUTH_INFOS 赋值）
Settings.SYSTEM_UID = nil

-- serverCloud 存储键
Settings.Keys = {
    QUESTION_STATS    = "question_stats",    -- 全局选题统计
    RESULT_STATS      = "result_stats",      -- 全局结果类型统计
    TEST_HISTORY      = "test_history",      -- 玩家测试历史（per-user）
    USER_CONTRIBUTION = "user_contribution", -- 用户上次答题贡献（用于去重）
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
}

return Settings
