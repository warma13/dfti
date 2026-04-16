-- ============================================================================
-- Shared.lua - 客户端/服务端共享代码
-- ============================================================================

local Shared = {}
local Settings = require("config.Settings")

Shared.Settings = Settings
Shared.EVENTS = Settings.EVENTS

-- 注册所有远程事件（客户端和服务端都必须调用）
function Shared.RegisterEvents()
    for _, eventName in pairs(Settings.EVENTS) do
        network:RegisterRemoteEvent(eventName)
    end
end

return Shared
