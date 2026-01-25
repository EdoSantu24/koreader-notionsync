-- Luacheck configuration for NotionSync KOReader Plugin

-- Ignore warnings
ignore = {
    "111", -- Setting undefined global variable
    "112", -- Mutating undefined global variable
    "113", -- Accessing undefined global variable
    "211", -- Unused local variable
    "212", -- Unused argument
    "213", -- Unused loop variable
}

-- Don't check line length
std = "max"
codes = true

-- KOReader framework globals
globals = {
    -- UI Components
    "UIManager",
    "InfoMessage",
    "InputDialog",
    "ButtonDialog",
    "PathChooser",
    "WidgetContainer",
    
    -- Core modules
    "logger",
    "require",
    "NetworkMgr",
    "DataStorage",
    "LuaSettings",
    "Dispatcher",
    
    -- Utilities
    "util",
    "Archiver",
    
    -- Standard Lua that luacheck might not recognize
    "setmetatable",
    "ipairs",
    "pairs",
    "type",
    "tostring",
    "tonumber",
}

-- Read-only globals
read_globals = {
    "debug",
    "io",
    "os",
    "string",
    "table",
    "math",
}

-- Files and directories to exclude
exclude_files = {
    "notionsync.koplugin/markdown.lua", -- External library
}
