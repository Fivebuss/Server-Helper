-- An attempt at making the MP experience bearable for once
-- Very early work in progress

-- Configuration
local CONFIG = {
    target_frametime_ms    = 16.666,     -- 60 fps
    target_fps             = 60,

    warn_at_fps            = 45,
    slow_physics_at_fps    = 38,
    slow_physics_minimum   = 0.20,

    critical_fps           = 10,
    critical_avg_fps       = 12,

    cleanup_at_fps         = 42,
    cleanup_at_avg_fps     = 42,

    -- Critical cleanup
    critical_build_cleanup_blocks = 200,

    physics_recovery_step  = 0.04,

    perf_history_length    = 5,
}

-- State
local state = {
    last_real_time     = tm.os.GetRealtimeSinceStartup(),
    frametime_ms       = CONFIG.target_frametime_ms,
    time_behind_ms     = 0,
    physics_percent    = 100,
    perf_history       = {},
    player_just_joined = false,
}

-- Only admin (players present at startup) will get the UI
local admin_player_ids = {}

-- Functions

local function log(msg)
    tm.os.Log("[ServerHelper] " .. msg)
end

-- Alert function
local function send_alert(target, header, message, duration, icon)
    duration = duration or 5
    icon = icon or "servericon"
    
    if target then
        -- single player
        tm.playerUI.AddSubtleMessageForPlayer(target, header, message, duration, icon)
    else
        -- broadcast to everyone
        tm.playerUI.AddSubtleMessageForAllPlayers(header, message, duration, icon)
    end
end

local function get_average_fps()
    if #state.perf_history == 0 then
        return CONFIG.target_fps
    end
    local sum = 0
    for _, v in ipairs(state.perf_history) do sum = sum + v end
    return sum / #state.perf_history
end

local function looks_like_build_mode(structure)
    local pos = structure.GetPosition()
    return math.abs(pos.y % 1) < 0.001
end

-- Compatibility with CMM
local function has_important_blocks(structure)
    local blocks = structure.GetBlocks()
    for _, block in ipairs(blocks) do
        if block.Exists() then
            local name = block.GetName()
            if block.IsPlayerSeatBlock()
                or name == "PFB_AnchorBlock"
                or name == "PFB_MixelEye_Sphere" then
                return true
            end
        end
    end
    return false
end

--- Returns approximate size
local function get_block_count(structure)
    local blocks = structure.GetBlocks()
    return #blocks
    -- return tm.physics.GetBuildComplexity() or #blocks
end

-- May be broken(!)
local function kick_player_out_of_build_mode(player_id)
    tm.players.SetBuilderEnabled(player_id, false)
    tm.players.SetRepairEnabled(player_id, false)
    log("Kicked player " .. tm.players.GetPlayerName(player_id) .. " out of build mode")
end

-- Cleans up structures
local function cleanup_all_structures()
    local count = 0
    local players = tm.players.CurrentPlayers()

    for _, p in ipairs(players) do
        local structures = tm.players.GetPlayerStructures(p.playerId)
        for _, structure in ipairs(structures) do
            structure.Dispose()
            count = count + 1
        end
    end

    if count > 0 then
        send_alert(nil, "Cleanup", "Removed " .. count .. " structures", 5)
        log("Cleanup removed " .. count .. " structures")
    end
    return count
end

-- Structures a player isnt driving
local function cleanup_unused_structures()
    local count = 0
    local players = tm.players.CurrentPlayers()

    for _, p in ipairs(players) do
        local structures = tm.players.GetPlayerStructures(p.playerId)
        for _, structure in ipairs(structures) do
            if looks_like_build_mode(structure) then
                -- skip build mode in normal cleanup
            elseif has_important_blocks(structure) then
                -- skip protected builds
            else
                structure.Dispose()
                count = count + 1
                log("Disposed unused structure owned by " .. tm.players.GetPlayerName(p.playerId))
            end
        end
    end

    if count > 0 then
        send_alert(nil, "Low Performance Cleanup", "Removed " .. count .. " unused structures", 4)
    end

    return count > 0
end

--- Critical performance 
local function emergency_cleanup_large_builds()
    local count = 0
    local players = tm.players.CurrentPlayers()

    for _, p in ipairs(players) do
        local player_id = p.playerId
        local playerName = tm.players.GetPlayerName(player_id)
        local structures = tm.players.GetPlayerStructures(player_id)

        for _, structure in ipairs(structures) do
            if looks_like_build_mode(structure)
               and not has_important_blocks(structure)
               and get_block_count(structure) >= CONFIG.critical_build_cleanup_blocks then

                local size = get_block_count(structure)
                structure.Dispose()
                count = count + 1
                log(string.format(
                    "CRITICAL destroyed large build-mode creations (%d blocks) by %s",
                    size, playerName
                ))
                
                -- Kick player out of build mode after deleting their build
                kick_player_out_of_build_mode(player_id)
            end
        end
    end

    if count > 0 then
        send_alert(nil, "CRITICAL Lag Protection", "Removed " .. count .. " very large unfinished builds", 6)
    end

    return count
end

-- Init
tm.os.SetModTargetDeltaTime(1/60)
tm.physics.AddTexture("server.png", "servericon")
log("Server helper started, target: " .. CONFIG.target_fps .. " fps")

-- Capture players who are already connected when the mod starts (usually just admin/host)
local initial_players = tm.players.CurrentPlayers()
for _, p in ipairs(initial_players) do
    table.insert(admin_player_ids, p.playerId)
    log("Admin player detected at startup: " .. tm.players.GetPlayerName(p.playerId) .. " (id " .. p.playerId .. ")")
end

-- Events
local function on_player_joined(callback)
    local player_id = callback.playerId
    local name = tm.players.GetPlayerName(player_id)
    log(name .. " joined (id " .. player_id .. ")")

    state.player_just_joined = true

    -- Only show UI to admin players (those present at mod init)
    local is_admin = false
    for _, admin_id in ipairs(admin_player_ids) do
        if admin_id == player_id then
            is_admin = true
            break
        end
    end

    if not is_admin then
        return  -- no UI for late joiners
    end

    local function label(id, text)
        tm.playerUI.AddUILabel(player_id, id, text)
    end

    label("header0",      "<color=#FC4><b>Server Performance</b></color>")
    label("avgfps",       "?.? avg FPS")
    label("spacer0",      "")
    label("rawfps",       "<color=#bbbbbb><i>?.? raw FPS</i></color>")
    label("frametime",    "<color=#bbbbbb><i>?.? ms</i></color>")
    label("spacer1",      "")
    label("header1",      "<color=#FC4><b>Status</b></color>")
    label("timebehind",   "0 ms behind")
    label("physspeed",    "100% physics")
    label("spacer2",      "")

    tm.playerUI.AddUIButton(player_id, "cleanall", "Clean ALL Builds", function()
        cleanup_all_structures()
    end, nil)
end

tm.players.OnPlayerJoined.add(on_player_joined)

-- Main update loop
function update()
    tm.os.SetModTargetDeltaTime(1/60)

    local now = tm.os.GetRealtimeSinceStartup()
    local dt = now - state.last_real_time
    state.last_real_time = now

    state.frametime_ms = dt * 1000
    state.time_behind_ms = state.frametime_ms - CONFIG.target_frametime_ms

    local current_fps = 1000 / math.max(state.frametime_ms, 1)

    table.insert(state.perf_history, current_fps)
    if #state.perf_history > CONFIG.perf_history_length then
        table.remove(state.perf_history, 1)
    end

    local avg_fps = get_average_fps()

    -- Decide actions
    local did_cleanup = false

    if current_fps <= CONFIG.critical_fps and avg_fps <= CONFIG.critical_avg_fps then
        log(string.format("CRITICAL LAG  %.1f fps (avg %.1f)", current_fps, avg_fps))

        local total_removed = cleanup_all_structures()
        local large_builds_removed = emergency_cleanup_large_builds()

        did_cleanup = (total_removed + large_builds_removed > 0)

    elseif current_fps <= CONFIG.cleanup_at_fps and avg_fps <= CONFIG.cleanup_at_avg_fps then
        if not state.player_just_joined then
            log(string.format("Low perf  %.1f fps (avg %.1f) cleaning unused", current_fps, avg_fps))
            did_cleanup = cleanup_unused_structures()
        end
    end

    -- Adjust physics timescale
    local target_scale = 1.0

    if current_fps <= CONFIG.slow_physics_at_fps and avg_fps <= CONFIG.slow_physics_at_fps + 5 then
        local lag_factor = (state.frametime_ms - CONFIG.target_frametime_ms) / CONFIG.target_frametime_ms
        target_scale = math.max(CONFIG.slow_physics_minimum, 1 / (1 + lag_factor * 1.5))
    end

    local current_scale = tm.physics.GetTimeScale()

    if target_scale < current_scale then
        tm.physics.SetTimeScale(target_scale)
        state.physics_percent = math.floor(target_scale * 100)
    elseif current_scale < 1 then
        local new_scale = math.min(1.0, current_scale + CONFIG.physics_recovery_step)
        tm.physics.SetTimeScale(new_scale)
        state.physics_percent = math.floor(new_scale * 100)
    end

    state.player_just_joined = false

    -- Update UI only for admin players
    for _, pid in ipairs(admin_player_ids) do
        -- Only update if the player still exists
        local player_exists = false
        local current_players = tm.players.CurrentPlayers()
        for _, p in ipairs(current_players) do
            if p.playerId == pid then
                player_exists = true
                break
            end
        end

        if player_exists then
            tm.playerUI.SetUIValue(pid, "avgfps",    string.format("%.1f avg FPS", avg_fps))
            tm.playerUI.SetUIValue(pid, "rawfps",    string.format("<color=#bbbbbb><i>%.1f raw FPS</i></color>", current_fps))
            tm.playerUI.SetUIValue(pid, "frametime", string.format("<color=#bbbbbb><i>%.1f ms</i></color>", state.frametime_ms))
            tm.playerUI.SetUIValue(pid, "timebehind", string.format("%.0f ms behind", math.max(0, state.time_behind_ms)))
            tm.playerUI.SetUIValue(pid, "physspeed",  string.format("%d%% physics", state.physics_percent))
        end
    end
end