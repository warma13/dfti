-- ============================================================================
-- main.lua - DFTI 人格测试 入口路由
-- 根据运行模式加载服务端或客户端模块
-- ============================================================================

local Module = nil

function Start()
    if IsServerMode() then
        print("[Main] Starting in SERVER mode")
        Module = require("network.Server")
    elseif IsNetworkMode() then
        print("[Main] Starting in CLIENT mode")
        Module = require("network.Client")
    else
        print("[Main] ERROR: This game requires network mode (server + client)")
    end

    if Module then
        Module.Start()
    end
end

function Stop()
    if Module and Module.Stop then
        Module.Stop()
    end
end
