-- ============================================================================
-- Server.lua - DFTI 服务端逻辑
-- 职责：
--   1. 维护全局选题统计和结果类型统计（内存 + serverCloud 持久化）
--   2. 响应客户端选择事件，返回统计数据
--   3. 保存玩家测试历史（最近 10 次）
-- ============================================================================

local Server = {}
local Shared = require("network.Shared")
local cjson = cjson ---@diagnostic disable-line: undefined-global
require "LuaScripts/Utilities/Sample"

-- ============================================================================
-- Mock graphics for headless mode
-- ============================================================================

if GetGraphics() == nil then
    local mockGraphics = {
        SetWindowIcon = function() end,
        SetWindowTitleAndIcon = function() end,
        GetWidth = function() return 1920 end,
        GetHeight = function() return 1080 end,
    }
    function GetGraphics() return mockGraphics end
    graphics = mockGraphics
    console = { background = {} }
    function GetConsole() return console end
    debugHud = {}
    function GetDebugHud() return debugHud end
end

-- ============================================================================
-- Constants
-- ============================================================================

local Settings = Shared.Settings
local EVENTS = Shared.EVENTS
local SYSTEM_UID = Settings.SYSTEM_UID
local Keys = Settings.Keys

-- ============================================================================
-- State
-- ============================================================================

-- 连接管理
local serverConnections_ = {}   -- connKey -> connection
local connectionUserIds_ = {}   -- connKey -> userId

-- 全局统计缓存（启动时从 serverCloud 加载）
-- questionStats[questionOriginalIndex][optionOriginalIndex] = count
-- questionStats[questionOriginalIndex].total = count
local questionStats_ = {}

-- resultStats[typeCode] = count, resultStats.total = count
local resultStats_ = { total = 0 }

-- 数据是否已加载
local statsLoaded_ = false

-- 统计未加载时的待处理请求队列
local pendingStatsRequests_ = {}   -- { {connection, questionId}, ... }

-- ============================================================================
-- Entry
-- ============================================================================

function Server.Start()
    SampleStart()
    Shared.RegisterEvents()

    -- 从 SERVER_PLAYER_AUTH_INFOS 获取真实用户 ID 作为全局数据存储的 uid
    local authInfos = SERVER_PLAYER_AUTH_INFOS ---@diagnostic disable-line: undefined-global
    if authInfos then
        for uid, _ in pairs(authInfos) do
            Settings.SYSTEM_UID = uid
            break
        end
    end
    if not Settings.SYSTEM_UID then
        Settings.SYSTEM_UID = 10001  -- dev mode fallback
    end
    SYSTEM_UID = Settings.SYSTEM_UID
    print("[Server] SYSTEM_UID=" .. tostring(SYSTEM_UID))

    -- 订阅网络事件
    SubscribeToEvent(EVENTS.CLIENT_READY, "HandleClientReady")
    SubscribeToEvent(EVENTS.OPTION_SELECTED, "HandleOptionSelected")
    SubscribeToEvent(EVENTS.TEST_COMPLETED, "HandleTestCompleted")
    SubscribeToEvent(EVENTS.REQUEST_HISTORY, "HandleRequestHistory")
    SubscribeToEvent(EVENTS.REQUEST_ALL_RESULTS, "HandleRequestAllResults")
    SubscribeToEvent("ClientDisconnected", "HandleClientDisconnected")

    print("[Server] DFTI Server started")
    print("[Server] serverCloud available: " .. tostring(serverCloud ~= nil))

    -- 从 serverCloud 加载全局统计
    LoadGlobalStats()
end

function Server.Stop()
end

-- ============================================================================
-- 数据加载
-- ============================================================================

function LoadGlobalStats()
    if serverCloud == nil then
        print("[Server] WARNING: serverCloud is nil, using empty stats")
        statsLoaded_ = true
        return
    end

    serverCloud:BatchGet(SYSTEM_UID)
        :Key(Keys.QUESTION_STATS)
        :Key(Keys.RESULT_STATS)
        :Fetch({
            ok = function(scores, iscores, sscores)
                -- 加载选题统计
                if scores and scores[Keys.QUESTION_STATS] then
                    local ok, data = pcall(cjson.decode, scores[Keys.QUESTION_STATS])
                    if ok and data then
                        -- 将字符串键转为数字键
                        for qk, qv in pairs(data) do
                            local qi = tonumber(qk)
                            if qi then
                                questionStats_[qi] = { total = qv.total or 0 }
                                for ok2, ov in pairs(qv) do
                                    local oi = tonumber(ok2)
                                    if oi then
                                        questionStats_[qi][oi] = ov
                                    end
                                end
                            end
                        end
                        print("[Server] Loaded question stats")
                    end
                end

                -- 加载结果统计
                if scores and scores[Keys.RESULT_STATS] then
                    local ok, data = pcall(cjson.decode, scores[Keys.RESULT_STATS])
                    if ok and data then
                        resultStats_ = data
                        if not resultStats_.total then
                            resultStats_.total = 0
                        end
                        print("[Server] Loaded result stats, total=" .. resultStats_.total)
                    end
                end

                statsLoaded_ = true
                print("[Server] Global stats loaded successfully")

                -- 处理等待中的统计请求
                for _, req in ipairs(pendingStatsRequests_) do
                    SendQuestionStatsResp(req[1], req[2])
                end
                pendingStatsRequests_ = {}
            end,
            error = function(code, reason)
                print("[Server] LoadGlobalStats ERROR: " .. tostring(code) .. " " .. tostring(reason))
                statsLoaded_ = true  -- 继续运行，使用空数据

                -- 处理等待中的统计请求（返回空数据总比不返回好）
                for _, req in ipairs(pendingStatsRequests_) do
                    SendQuestionStatsResp(req[1], req[2])
                end
                pendingStatsRequests_ = {}
            end,
        })
end

--- 持久化选题统计到 serverCloud
local function PersistQuestionStats()
    if serverCloud == nil then return end
    local jsonStr = cjson.encode(questionStats_)
    serverCloud:Set(SYSTEM_UID, Keys.QUESTION_STATS, jsonStr, {
        ok = function()
            print("[Server] Question stats persisted")
        end,
        error = function(code, reason)
            print("[Server] PersistQuestionStats ERROR: " .. tostring(code) .. " " .. tostring(reason))
        end,
    })
end

--- 持久化结果统计到 serverCloud
local function PersistResultStats()
    if serverCloud == nil then return end
    local jsonStr = cjson.encode(resultStats_)
    serverCloud:Set(SYSTEM_UID, Keys.RESULT_STATS, jsonStr, {
        ok = function()
            print("[Server] Result stats persisted")
        end,
        error = function(code, reason)
            print("[Server] PersistResultStats ERROR: " .. tostring(code) .. " " .. tostring(reason))
        end,
    })
end

-- ============================================================================
-- 连接管理
-- ============================================================================

function HandleClientReady(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = tostring(connection)

    -- 获取 userId
    local userId = 10001  -- dev mode fallback
    local identityUid = connection.identity["user_id"]
    if identityUid then
        userId = identityUid:GetInt64()
    end

    serverConnections_[connKey] = connection
    connectionUserIds_[connKey] = userId

    -- 把 userId 发回客户端
    local infoData = VariantMap()
    infoData["UserId"] = Variant(tostring(userId))
    connection:SendRemoteEvent(EVENTS.CLIENT_INFO, true, infoData)

    print("[Server] ClientReady userId=" .. tostring(userId))
end

function HandleClientDisconnected(eventType, eventData)
    local connection = eventData:GetPtr("Connection", "Connection")
    local connKey = tostring(connection)
    local userId = connectionUserIds_[connKey]

    serverConnections_[connKey] = nil
    connectionUserIds_[connKey] = nil

    print("[Server] Client disconnected userId=" .. tostring(userId))
end

-- ============================================================================
-- 选题统计处理
-- ============================================================================

--- 发送某题的统计数据给客户端
function SendQuestionStatsResp(connection, questionId)
    local qs = questionStats_[questionId] or { total = 0 }
    local counts = {}
    for k, v in pairs(qs) do
        if type(k) == "number" then
            counts[tostring(k)] = v
        end
    end

    local respData = VariantMap()
    respData["Data"] = Variant(cjson.encode({
        questionId = questionId,
        counts = counts,
        total = qs.total or 0,
    }))
    connection:SendRemoteEvent(EVENTS.OPTION_STATS_RESP, true, respData)
end

--- 只读：返回当前统计数据，不修改计数（等测试完成后统一写入）
function HandleOptionSelected(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = tostring(connection)
    local userId = connectionUserIds_[connKey]
    if not userId then return end

    local questionId = eventData["QuestionId"]:GetInt()
    local optionId = eventData["OptionId"]:GetInt()

    print(string.format("[Server] OptionSelected (read-only) userId=%s q=%d o=%d",
        tostring(userId), questionId, optionId))

    -- 统计数据尚未加载完成，排队等待
    if not statsLoaded_ then
        print("[Server] Stats not loaded yet, queuing request")
        table.insert(pendingStatsRequests_, { connection, questionId })
        return
    end

    SendQuestionStatsResp(connection, questionId)
end

-- ============================================================================
-- 测试完成处理（批量写入 + 每用户去重）
-- ============================================================================

--- 应用答题差量：减去旧贡献，加上新贡献，持久化并回传统计
local function ApplyAnswersDelta(oldContribution, newAnswers, typeCode, userId, connection)
    -- 1. 减去旧贡献（如果用户之前做过测试）
    if oldContribution then
        local oldAnswers = oldContribution.answers or {}
        for _, ans in ipairs(oldAnswers) do
            local qi = ans.questionId
            local oi = ans.optionId
            if questionStats_[qi] then
                questionStats_[qi][oi] = math.max(0, (questionStats_[qi][oi] or 0) - 1)
                questionStats_[qi].total = math.max(0, (questionStats_[qi].total or 0) - 1)
            end
        end
        -- 减去旧结果类型统计
        local oldResult = oldContribution.result
        if oldResult and resultStats_[oldResult] then
            resultStats_[oldResult] = math.max(0, resultStats_[oldResult] - 1)
            resultStats_.total = math.max(0, (resultStats_.total or 0) - 1)
        end
        print(string.format("[Server] Subtracted old contribution for userId=%s (old result=%s, %d answers)",
            tostring(userId), tostring(oldResult), #oldAnswers))
    end

    -- 2. 加上新贡献
    for _, ans in ipairs(newAnswers) do
        local qi = ans.questionId
        local oi = ans.optionId
        if not questionStats_[qi] then
            questionStats_[qi] = { total = 0 }
        end
        questionStats_[qi][oi] = (questionStats_[qi][oi] or 0) + 1
        questionStats_[qi].total = (questionStats_[qi].total or 0) + 1
    end

    -- 更新结果类型统计
    resultStats_[typeCode] = (resultStats_[typeCode] or 0) + 1
    resultStats_.total = (resultStats_.total or 0) + 1

    -- 3. 持久化统计数据
    PersistQuestionStats()
    PersistResultStats()

    -- 4. 保存新贡献记录（用于下次去重）
    if serverCloud then
        local contribution = {
            answers = newAnswers,
            result = typeCode,
            timestamp = os.time(),
        }
        serverCloud:Set(userId, Keys.USER_CONTRIBUTION, cjson.encode(contribution), {
            ok = function()
                print("[Server] Saved contribution for userId=" .. tostring(userId))
            end,
            error = function(code, reason)
                print("[Server] SaveContribution ERROR: " .. tostring(code) .. " " .. tostring(reason))
            end,
        })
    end

    -- 5. 回传结果统计给客户端
    local respData = VariantMap()
    respData["Data"] = Variant(cjson.encode({
        typeCode = typeCode,
        count = resultStats_[typeCode] or 0,
        total = resultStats_.total or 0,
    }))
    connection:SendRemoteEvent(EVENTS.RESULT_STATS_RESP, true, respData)

    print(string.format("[Server] Applied delta for userId=%s, result=%s, %d answers",
        tostring(userId), typeCode, #newAnswers))
end

function HandleTestCompleted(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = tostring(connection)
    local userId = connectionUserIds_[connKey]
    if not userId then return end

    local dataJson = eventData["Data"]:GetString()
    local ok, data = pcall(cjson.decode, dataJson)
    if not ok or not data then
        print("[Server] TestCompleted: invalid data from userId=" .. tostring(userId))
        return
    end

    local typeCode = data.result or "UNKNOWN"
    local answers = data.answers or {}

    print(string.format("[Server] TestCompleted userId=%s result=%s answers=%d",
        tostring(userId), typeCode, #answers))

    -- 去重处理：读取用户上次贡献，减去旧数据后加上新数据
    if serverCloud then
        serverCloud:Get(userId, Keys.USER_CONTRIBUTION, {
            ok = function(scores, iscores)
                local oldContribution = nil
                if scores and scores[Keys.USER_CONTRIBUTION] then
                    local ok2, parsed = pcall(cjson.decode, scores[Keys.USER_CONTRIBUTION])
                    if ok2 and type(parsed) == "table" then
                        oldContribution = parsed
                    end
                end
                ApplyAnswersDelta(oldContribution, answers, typeCode, userId, connection)
            end,
            error = function(code, reason)
                -- 读取失败，视为首次测试（无旧数据）
                print("[Server] Get USER_CONTRIBUTION error: " .. tostring(reason))
                ApplyAnswersDelta(nil, answers, typeCode, userId, connection)
            end,
        })
    else
        -- 无 serverCloud，直接应用（不持久化）
        ApplyAnswersDelta(nil, answers, typeCode, userId, connection)
    end

    -- 保存玩家测试历史
    SavePlayerHistory(userId, data)
end

--- 处理客户端请求历史记录
function HandleRequestHistory(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = tostring(connection)
    local userId = connectionUserIds_[connKey]
    if not userId then return end

    print("[Server] RequestHistory from userId=" .. tostring(userId))

    if serverCloud == nil then
        -- 无 serverCloud，返回空列表
        local respData = VariantMap()
        respData["Data"] = Variant(cjson.encode({ history = {} }))
        connection:SendRemoteEvent(EVENTS.HISTORY_RESP, true, respData)
        return
    end

    serverCloud:Get(userId, Keys.TEST_HISTORY, {
        ok = function(scores, iscores)
            local history = {}
            if scores and scores[Keys.TEST_HISTORY] then
                local ok2, parsed = pcall(cjson.decode, scores[Keys.TEST_HISTORY])
                if ok2 and type(parsed) == "table" then
                    history = parsed
                end
            end

            local respData = VariantMap()
            respData["Data"] = Variant(cjson.encode({ history = history }))
            connection:SendRemoteEvent(EVENTS.HISTORY_RESP, true, respData)
            print("[Server] Sent history to userId=" .. tostring(userId) .. " count=" .. #history)
        end,
        error = function(code, reason)
            print("[Server] GetHistory ERROR: " .. tostring(code) .. " " .. tostring(reason))
            local respData = VariantMap()
            respData["Data"] = Variant(cjson.encode({ history = {} }))
            connection:SendRemoteEvent(EVENTS.HISTORY_RESP, true, respData)
        end,
    })
end

-- ============================================================================
-- 全部人格统计请求
-- ============================================================================
function HandleRequestAllResults(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local respData = VariantMap()
    respData["Data"] = Variant(cjson.encode(resultStats_))
    connection:SendRemoteEvent(EVENTS.ALL_RESULTS_RESP, true, respData)
    print("[Server] Sent all result stats, total=" .. (resultStats_.total or 0))
end

--- 保存玩家测试历史（最近 10 次）
function SavePlayerHistory(userId, testData)
    if serverCloud == nil then return end

    -- 先读取现有历史
    serverCloud:Get(userId, Keys.TEST_HISTORY, {
        ok = function(scores, iscores)
            local history = {}
            if scores and scores[Keys.TEST_HISTORY] then
                local ok2, existing = pcall(cjson.decode, scores[Keys.TEST_HISTORY])
                if ok2 and type(existing) == "table" then
                    history = existing
                end
            end

            -- 追加新记录
            table.insert(history, {
                timestamp = os.time(),
                result = testData.result,
                scores = testData.scores,
                answers = testData.answers,
            })

            -- 只保留最近 N 条
            while #history > Settings.MAX_HISTORY do
                table.remove(history, 1)
            end

            -- 写回
            serverCloud:Set(userId, Keys.TEST_HISTORY, cjson.encode(history), {
                ok = function()
                    print("[Server] Saved history for userId=" .. tostring(userId) .. " count=" .. #history)
                end,
                error = function(code, reason)
                    print("[Server] SaveHistory ERROR: " .. tostring(code) .. " " .. tostring(reason))
                end,
            })
        end,
        error = function(code, reason)
            -- 读取失败，创建新历史
            local history = { {
                timestamp = os.time(),
                result = testData.result,
                scores = testData.scores,
                answers = testData.answers,
            } }
            serverCloud:Set(userId, Keys.TEST_HISTORY, cjson.encode(history), {
                ok = function()
                    print("[Server] Created new history for userId=" .. tostring(userId))
                end,
                error = function(code2, reason2)
                    print("[Server] CreateHistory ERROR: " .. tostring(code2) .. " " .. tostring(reason2))
                end,
            })
        end,
    })
end

return Server
