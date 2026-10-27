_addon.name     = 'DigTracker'
_addon.author   = 'peterjez'
_addon.version  = '3.2'
_addon.commands = {'dt', 'digtracker'}

-- Load Windower Libraries
local config = require('config')
local texts  = require('texts')
local files  = require('files')
require('strings')

-----------------------------------------------------------------------
-- Default Settings & Persistent State Files
-----------------------------------------------------------------------
local default_settings = {
    hud = {
        text = { font = 'Consolas', size = 10, alpha = 255 },
        pos = { x = 685, y = 600 },
        bg = { alpha = 150, red = 0, green = 0, blue = 0 },
        visible = true,
        locked = false,
        flags = { draggable = true }
    },
    show_items = true
}

local settings = config.load(default_settings)

-- Character-specific data file
local player = windower.ffxi.get_player()

local character = 'default'
if player and player.name then
    character = player.name
end

local stats_file_path = ('data/%s.lua'):format(character)
local stats_file = files.new(stats_file_path)

-- Establish Default Local Stats State
local persistent_stats = {
    total_digs = 0,
    successful_digs = 0,
    failed_digs = 0,
    conquest_points = 0,
    current_skill = 0,
    digs_since_skillup = 0, -- Moved here to allow persistent tracking across logouts
    items = {},
    skillups = {}
}

-- Load stats from flat file safely
if stats_file:exists() then
    local loaded_data = loadfile(windower.addon_path .. stats_file_path)
    if loaded_data then
        local success, result = pcall(loaded_data)
        if success and type(result) == 'table' then
            persistent_stats = result
            -- Structural safety migration for existing old files
            if not persistent_stats.digs_since_skillup then
                persistent_stats.digs_since_skillup = 0
            end
        end
    end
end

-- Session-only tracking variables
local session = {
    start_time = os.time(),
    digs = 0,
    successes = 0,
    fails = 0,
    conquest_points = 0,
    last_skill_interval = 0,
    items = {}
}

-- Initialize text HUD display
local hud = texts.new(settings.hud)

-----------------------------------------------------------------------
-- Helper Functions & Math
-----------------------------------------------------------------------
-- Surgically removes FFXI auto-translate and style bytes using decimal codes
local function clean_string(str)
    if not str then return "" end
    
    local cleaned = str
    
    -- 1. Strip Windower's color tags (\127 followed by hex colors)
    cleaned = cleaned:gsub('\127%x%x%x%x%x%x%x', ''):gsub('\127', '')
    
    -- 2. Strip FFXI auto-translate control byte sequences (\253\002\002....)
    cleaned = cleaned:gsub('\253\002\002%.%.%.%.', '') 
    
    -- 3. Strip specific FFXI system and color control bytes using decimal codes:
    cleaned = cleaned:gsub('[\253\031\030\029\028\027\026\001\002\003\127]', '')
    
    -- 4. Collapse duplicate spaces and trim the ends
    cleaned = cleaned:gsub('%s+', ' ')
    return cleaned:trim()
end

-- Safely serializes our custom table into a pure, clean Lua data file
local function save_data()
    -- Save XML Settings
    config.save(settings)
    
    -- Save Flat Lua Stats
    local output = {}
    output[#output+1] = "return {"
    output[#output+1] = string.format("    total_digs = %d,", persistent_stats.total_digs)
    output[#output+1] = string.format("    successful_digs = %d,", persistent_stats.successful_digs)
    output[#output+1] = string.format("    failed_digs = %d,", persistent_stats.failed_digs)
    output[#output+1] = string.format("    conquest_points = %d,", persistent_stats.conquest_points)
    output[#output+1] = string.format("    current_skill = %d,", persistent_stats.current_skill)
    output[#output+1] = string.format("    digs_since_skillup = %d,", persistent_stats.digs_since_skillup or 0)
    
    -- Write items
    output[#output+1] = "    items = {"
    for item, count in pairs(persistent_stats.items) do
        -- Escape any single quotes safely
        local safe_item = item:gsub("'", "\\'")
        output[#output+1] = string.format("        ['%s'] = %d,", safe_item, count)
    end
    output[#output+1] = "    },"
    
    -- Write skillups
    output[#output+1] = "    skillups = {"
    for _, val in ipairs(persistent_stats.skillups) do
        output[#output+1] = string.format("        '%s',", val)
    end
    output[#output+1] = "    }"
    output[#output+1] = "}"
    
    stats_file:write(table.concat(output, "\n"))
end

local function get_rates()
    local duration = math.max(1, os.time() - session.start_time)
    local hours = duration / 3600
    
    local total = session.digs
    local success_rate = total > 0 and (session.successes / total) * 100 or 0
    local digs_per_hour = total / hours
    local success_per_hour = session.successes / hours
    
    -- Decode our flat string list back into math values
    local skill_count = #persistent_stats.skillups
    local avg_interval = 0
    local best_interval = "N/A"
    local worst_interval = "N/A"
    
    if skill_count > 1 then
        local total_intervals = 0
        local min_int = 999999
        local max_int = 0
        
        for i = 2, skill_count do
            -- Decode "skill|interval|timestamp" format
            local parts = persistent_stats.skillups[i]:split('|')
            local interval = tonumber(parts[2]) or 0
            
            total_intervals = total_intervals + interval
            if interval < min_int then min_int = interval end
            if interval > max_int then max_int = interval end
        end
        
        avg_interval = total_intervals / (skill_count - 1)
        best_interval = tostring(min_int)
        worst_interval = tostring(max_int)
    end
    
    local indicator = "---"
    local current_interval = persistent_stats.digs_since_skillup or 0
    if avg_interval > 0 and current_interval > 0 then
        if current_interval > avg_interval then
            indicator = "\\cs(255,100,100)DUE (Above Avg)\\cr"
        else
            indicator = "\\cs(100,255,100)Below Avg\\cr"
        end
    end

    return success_rate, digs_per_hour, success_per_hour, avg_interval, best_interval, worst_interval, indicator
end

local function update_hud()
    if not settings.hud.visible then 
        hud:hide()
        return 
    end
    
    local success_rate, digs_per_hour, success_per_hour, avg_interval, best_interval, worst_interval, indicator = get_rates()
    
    local info = {}
    info[#info+1] = "== \\cs(0,255,255)Dig Tracker\\cr =="
    info[#info+1] = string.format("Digs (Session): %d | Failed: %d", session.digs, session.fails)
    info[#info+1] = string.format("Successes: %d (%.1f%%)", session.successes, success_rate)
    info[#info+1] = string.format("Speed: %.1f digs/hr | %.1f items/hr", digs_per_hour, success_per_hour)
    
    if session.conquest_points > 0 then
        info[#info+1] = string.format("Conquest Points: %d (Total: %d)", session.conquest_points, persistent_stats.conquest_points)
    end
    
    info[#info+1] = "--------------------------"
    info[#info+1] = string.format("Current Wing Skill: %s", persistent_stats.current_skill > 0 and tostring(persistent_stats.current_skill) or "Unknown")
    info[#info+1] = string.format("Digs Since Last Skill: %d", persistent_stats.digs_since_skillup or 0)
    info[#info+1] = string.format("Avg Interval: %.1f | Best/Worst: %s/%s", avg_interval, best_interval, worst_interval)
    info[#info+1] = string.format("Status: %s", indicator)
    
    if settings.show_items then
        info[#info+1] = "--------------------------"
        info[#info+1] = "\\cs(255,255,100)Items Looted (Session):\\cr"
        local has_items = false
        for item, count in pairs(session.items) do
            info[#info+1] = string.format("  %s: %d", item, count)
            has_items = true
        end
        if not has_items then info[#info+1] = "  None" end
    end
    
    hud:text(table.concat(info, '\n'))
    hud:show()
end

local function export_csv()
    local path = 'logs/dig_history.csv'
    local log_file = files.new(path)
    
    if not log_file:exists() then
        log_file:write("Timestamp,Total Session Digs,Result,Item,Current Skill\n")
    end
    
    local timestamp = os.date('%Y-%m-%d %H:%M:%S')
    return log_file, timestamp
end

-----------------------------------------------------------------------
-- Log Event Parsers
-----------------------------------------------------------------------
windower.register_event('incoming text', function(original, modified, mode, restored)
    if not original or original == '' then return end

    -- Only track dig results while riding a chocobo
    local current_player = windower.ffxi.get_player()
    if not current_player or current_player.status ~= 5 then
        return
    end

    local clean_text = clean_string(original)

    -------------------------------------------------------------------
    -- Match 1: Failed Dig
    -------------------------------------------------------------------
    if clean_text:find('You dig and you dig, but find nothing%.') then
        session.digs = session.digs + 1
        session.fails = session.fails + 1
        persistent_stats.digs_since_skillup = (persistent_stats.digs_since_skillup or 0) + 1
        
        persistent_stats.total_digs = persistent_stats.total_digs + 1
        persistent_stats.failed_digs = persistent_stats.failed_digs + 1
        save_data()
        
        local log_file, ts = export_csv()
        log_file:append(string.format("%s,%d,Fail,None,%d\n", ts, session.digs, persistent_stats.current_skill))
        
        update_hud()
        return
    end

    -------------------------------------------------------------------
    -- Match 2: Successful Cache Find (Beastman Resources / CP)
    -------------------------------------------------------------------
    local cp_match = clean_text:match('You discover a cache of beastman resources and receive (%d+) conquest points!')
    if cp_match then
        local cp_amount = tonumber(cp_match)
        
        session.digs = session.digs + 1
        session.successes = session.successes + 1
        persistent_stats.digs_since_skillup = (persistent_stats.digs_since_skillup or 0) + 1
        
        session.conquest_points = session.conquest_points + cp_amount
        persistent_stats.conquest_points = (persistent_stats.conquest_points or 0) + cp_amount
        
        session.items['Beastman Cache (CP)'] = (session.items['Beastman Cache (CP)'] or 0) + 1
        
        persistent_stats.total_digs = persistent_stats.total_digs + 1
        persistent_stats.successful_digs = persistent_stats.successful_digs + 1
        persistent_stats.items['Beastman Cache (CP)'] = (persistent_stats.items['Beastman Cache (CP)'] or 0) + 1
        save_data()
        
        local log_file, ts = export_csv()
        log_file:append(string.format("%s,%d,Success,\"Beastman Cache (%d CP)\",%d\n", ts, session.digs, cp_amount, persistent_stats.current_skill))
        
        update_hud()
        return
    end

    -------------------------------------------------------------------
    -- Match 3: Successful Dig (Standard Items)
    -------------------------------------------------------------------
    local item_match = original:match('Obtained:%s*(.-)%.')
    if item_match then
        item_match = clean_string(item_match)
        
        if item_match ~= "" then
            session.digs = session.digs + 1
            session.successes = session.successes + 1
            persistent_stats.digs_since_skillup = (persistent_stats.digs_since_skillup or 0) + 1
            
            -- Track in session (displays in HUD)
            session.items[item_match] = (session.items[item_match] or 0) + 1
            
            -- Track in persistent records safely
            persistent_stats.total_digs = persistent_stats.total_digs + 1
            persistent_stats.successful_digs = persistent_stats.successful_digs + 1
            persistent_stats.items[item_match] = (persistent_stats.items[item_match] or 0) + 1
            save_data()
            
            local log_file, ts = export_csv()
            log_file:append(string.format("%s,%d,Success,\"%s\",%d\n", ts, session.digs, item_match, persistent_stats.current_skill))
            
            update_hud()
            return
        end
    end

    -------------------------------------------------------------------
    -- Match 4: Skill Up
    -------------------------------------------------------------------
    local skill = clean_text:match('Your%s+wing%s+skill%s+improved%s+to%s+(%d+)!')
    if skill then
        local skill_num = tonumber(skill)
        local current_interval = persistent_stats.digs_since_skillup or 0
        
        local serialized_skillup = string.format("%d|%d|%d", skill_num, current_interval, os.time())
        table.insert(persistent_stats.skillups, serialized_skillup)
        
        persistent_stats.current_skill = skill_num
        session.last_skill_interval = current_interval
        persistent_stats.digs_since_skillup = 0
        save_data()
        
        windower.add_to_chat(207, string.format('[DigTracker] Registered skill up to %d after %d digs!', skill_num, current_interval))
        
        update_hud()
        return
    end
end)

-----------------------------------------------------------------------
-- UI Update Loop & Drag Coordinate Sync
-----------------------------------------------------------------------
windower.register_event('prerender', function()
    local x, y = hud:pos()
    if x ~= settings.hud.pos.x or y ~= settings.hud.pos.y then
        settings.hud.pos.x = x
        settings.hud.pos.y = y
        save_data()
    end

    if os.time() % 2 == 0 then
        update_hud()
    end
end)

-----------------------------------------------------------------------
-- Command Handler
-----------------------------------------------------------------------
windower.register_event('addon command', function(...)
    local args = {...}
    local cmd = args[1] and args[1]:lower() or 'help'
    
    if cmd == 'toggle' then
        settings.hud.visible = not settings.hud.visible
        save_data()
        update_hud()
        windower.add_to_chat(207, '[DigTracker] HUD Visibility toggled.')
        
    elseif cmd == 'items' then
        settings.show_items = not settings.show_items
        save_data()
        update_hud()
        windower.add_to_chat(207, '[DigTracker] Item display toggled.')
        
    elseif cmd == 'lock' then
        settings.hud.locked = not settings.hud.locked
        hud:draggable(not settings.hud.locked)
        save_data()
        windower.add_to_chat(207, '[DigTracker] HUD position ' .. (settings.hud.locked and 'Locked' or 'Unlocked') .. '.')
        
    elseif cmd == 'reset' then
        local sub_cmd = args[2] and args[2]:lower() or 'all'
        
        if sub_cmd == 'all' or sub_cmd == 'session' then
            session.digs = 0
            session.successes = 0
            session.fails = 0
            session.conquest_points = 0
            session.items = {}
            session.start_time = os.time()
        end
        
        if sub_cmd == 'all' or sub_cmd == 'persistent' then
            persistent_stats = {
                total_digs = 0,
                successful_digs = 0,
                failed_digs = 0,
                conquest_points = 0,
                items = {},
                skillups = {},
                current_skill = 0,
                digs_since_skillup = 0
            }
            save_data()
        end
        
        windower.add_to_chat(207, string.format('[DigTracker] Reset executed for: %s', sub_cmd))
        update_hud()
        
    else
        windower.add_to_chat(207, '===== Dig Tracker Commands =====')
        windower.add_to_chat(207, '//dt toggle : Show/Hide HUD overlay')
        windower.add_to_chat(207, '//dt items  : Toggle showing inventory items listing on HUD')
        windower.add_to_chat(207, '//dt lock   : Lock/Unlock mouse dragging functionality')
        windower.add_to_chat(207, '//dt reset session    : Resets current session timers/counts')
        windower.add_to_chat(207, '//dt reset persistent : Clears historic intervals and totals')
        windower.add_to_chat(207, '//dt reset all        : Erases all statistics completely')
    end
end)

-- Initialization
local function initialize_player_file()
    local player = windower.ffxi.get_player()
    if not player then
        return
    end

    character = player.name
    stats_file_path = ('data/%s.lua'):format(character)
    stats_file = files.new(stats_file_path)

    -- Reload persistent stats
    if stats_file:exists() then
        local loaded = loadfile(windower.addon_path .. stats_file_path)
        if loaded then
            local success, result = pcall(loaded)
            if success and type(result) == 'table' then
                persistent_stats = result
                if not persistent_stats.digs_since_skillup then
                    persistent_stats.digs_since_skillup = 0
                end
            end
        end
    end

    update_hud()
end

windower.register_event('load', function()
    hud:draggable(not settings.hud.locked)
    initialize_player_file()
    windower.add_to_chat(207,
        ('[DigTracker] Loaded using %s'):format(stats_file_path))
end)

windower.register_event('login', initialize_player_file)
