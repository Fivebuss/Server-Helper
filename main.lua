-- An attempt at making the MP experience bearable for once
-- Server performance & stability helper

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

    -- Ambient cleanup
    min_ambientclean_amount     = 25,       -- How big is a small debris?
    ambientclean_interval_sec   = 5.0,      -- how often to scan

    -- block limits, use the internal name, good luck on that
    block_limits = {
        PFB_BombRack = 5
        -- PFB_RocketPod = 4,
        -- PFB_FlakCannon = 3,
        -- etc...
    },

    -- Debug logging
    debug = false,
}

-- State
local state = {
    last_real_time          = tm.os.GetRealtimeSinceStartup(),
    frametime_ms            = CONFIG.target_frametime_ms,
    time_behind_ms          = 0,
    physics_percent         = 100,
    perf_history            = {},
    player_just_joined      = false,
    last_cleanup_scan       = 0,
}

-- Only players present at mod start get admin UI
local admin_player_ids = {}

-- Functions
local function log(msg)
    tm.os.Log("[ServerHelper] " .. msg)
end

local function send_alert(target, header, message, duration, icon)
    duration = duration or 5
    icon = icon or "servericon"

    if target then
        tm.playerUI.AddSubtleMessageForPlayer(target, header, message, duration, icon)
    else
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

local function is_player_in_build_mode(player_id)
    return tm.players.GetPlayerIsInBuildMode(player_id)
end

-- CMM compatbility
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

-- Is a player driving it?
local function has_seated_player(structure)
    local blocks = structure.GetBlocks()
    for _, block in ipairs(blocks) do
        if block.IsPlayerSeatBlock() and block.Exists() then
            return true
        end
    end
    return false
end

local function get_block_count(structure)
    local blocks = structure.GetBlocks()
    return #blocks
end

-- May be broken
local function kick_player_out_of_build_mode(player_id)
    tm.players.SetBuilderEnabled(player_id, false)
    tm.players.SetRepairEnabled(player_id, false)
    log("Kicked player " .. tm.players.GetPlayerName(player_id) .. " out of build mode")
end

-- Ambient cleanup and block limits
local function cleanup_structures_loop()
    local now = tm.os.GetTime()
    if now - state.last_cleanup_scan < CONFIG.ambientclean_interval_sec then
        return 0
    end
    state.last_cleanup_scan = now

    local removed = 0
    local players = tm.players.CurrentPlayers()

    for _, p in ipairs(players) do
        local player_id = p.playerId
        local playerName = tm.players.GetPlayerName(player_id)

        if is_player_in_build_mode(player_id) then
            -- skip this player if in build mode
        else
            local structures = tm.players.GetPlayerStructures(player_id)

            for _, structure in ipairs(structures) do
                local block_count = get_block_count(structure)
                local in_build_mode = looks_like_build_mode(structure)

                -- Count blocks per type
                local blocks = structure.GetBlocks()
                local block_type_counts = {}
                for _, block in ipairs(blocks) do
                    if block.Exists() then
                        local name = block.GetName()
                        block_type_counts[name] = (block_type_counts[name] or 0) + 1
                    end
                end

                -- Block limits
                local limit_triggered = false
                local triggered_block = nil
                local triggered_count = 0
                local triggered_limit = 0

                for blockName, limit in pairs(CONFIG.block_limits) do
                    local count = block_type_counts[blockName] or 0
                    if count >= limit then
                        limit_triggered = true
                        triggered_block = blockName
                        triggered_count = count
                        triggered_limit = limit
                        break
                    end
                end
                
                -- Do stuff if the limit was passed
                if limit_triggered then
                    if CONFIG.debug then
                        log("Removing build from " .. playerName .. ", exceeded " .. triggered_block .. " limit (" .. triggered_count .. "/" .. triggered_limit .. ")")
                    end
                    structure.Destroy()
                    removed = removed + 1
                    send_alert(player_id,
                        "Build Removed",
                        "Exceeded limit of " .. triggered_limit .. " for " .. triggered_block,
                        6)
                    --log("Removed build from " .. playerName .. " for exceeding " .. triggered_block .. " limit (" .. triggered_count .. ")")

                    if in_build_mode then
                        kick_player_out_of_build_mode(player_id)
                    end

                -- Ambient cleanup of small abandoned debris
                elseif not in_build_mode
                    and block_count <= CONFIG.min_ambientclean_amount
                    and block_count > 0
                    and not has_seated_player(structure)
                    and not has_important_blocks(structure) then

                    if CONFIG.debug then
                        log("Ambient cleanup triggered on " .. block_count .. " block debris from " .. playerName)
                    end
                    structure.Destroy()
                    removed = removed + 1
                end
            end
        end
    end

    return removed
end

-- Clean everything (admin button)
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
        send_alert(nil, "Admin Cleanup", "Removed " .. count .. " structures", 5)
        log("Admin cleanup removed " .. count .. " structures")
    end
    return count
end

-- Clean structures that arent being drived
local function cleanup_unused_structures()
    local count = 0
    local players = tm.players.CurrentPlayers()

    for _, p in ipairs(players) do
        local player_id = p.playerId
        local playerName = tm.players.GetPlayerName(player_id)

        if is_player_in_build_mode(player_id) then
            -- skip
        else
            local structures = tm.players.GetPlayerStructures(player_id)
            for _, structure in ipairs(structures) do
                if looks_like_build_mode(structure) then
                    -- skip build mode shapes
                elseif has_important_blocks(structure) then
                    -- skip protected builds
                else
                    if CONFIG.debug then
                        log("Disposed unused structure owned by " .. playerName)
                    end
                    --structure.Destroy()
                    structure.Dispose()
                    count = count + 1            
                end
            end
        end
    end

    if count > 0 then
        send_alert(nil, "Low Performance Cleanup", "Removed " .. count .. " unused structures", 4)
    end

    return count > 0
end

-- Big lag so remove everything large unfinished builds
local function emergency_cleanup_large_builds()
    local count = 0
    local players = tm.players.CurrentPlayers()

    for _, p in ipairs(players) do
        local player_id = p.playerId
        local playerName = tm.players.GetPlayerName(player_id)

        if is_player_in_build_mode(player_id) then
            -- skip
        else
            local structures = tm.players.GetPlayerStructures(player_id)

            for _, structure in ipairs(structures) do
                if looks_like_build_mode(structure)
                   --and not has_important_blocks(structure)
                   and get_block_count(structure) >= CONFIG.critical_build_cleanup_blocks then

                    local size = get_block_count(structure)

                    log(string.format(
                        "CRITICAL destroyed large build-mode creation (%d blocks) by %s",
                        size, playerName
                        ))
                    --structure.Destroy()

                    structure.Dispose()
                    count = count + 1
                    
                    kick_player_out_of_build_mode(player_id)
                end
            end
        end
    end

    if count > 0 then
        send_alert(nil, "Horrendous lag: ", "Removed " .. count .. " builds", 6)
    end

    return count
end

-- Init
tm.os.SetModTargetDeltaTime(1/60)
tm.physics.AddTexture("server.png", "servericon")
log("Server helper started, target: " .. CONFIG.target_fps .. " fps, debug logging: " .. tostring(CONFIG.debug))

-- Determine the host
local initial_players = tm.players.CurrentPlayers()
for _, p in ipairs(initial_players) do
    table.insert(admin_player_ids, p.playerId)
    log("Admin detected at startup: " .. tm.players.GetPlayerName(p.playerId) .. " (id " .. p.playerId .. ")")
end

-- Player join and UI stuff
local function on_player_joined(callback)
    local player_id = callback.playerId
    local name = tm.players.GetPlayerName(player_id)
    log(name .. " joined (id " .. player_id .. ")")

    state.player_just_joined = true

    local is_admin = false
    for _, admin_id in ipairs(admin_player_ids) do
        if admin_id == player_id then
            is_admin = true
            break
        end
    end

    if not is_admin then return end

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

    -- Main cleanup buttons
    tm.playerUI.AddUIButton(player_id, "cleanall",       "Clean ALL Builds",       function() cleanup_all_structures()       end, nil)
    tm.playerUI.AddUIButton(player_id, "clean_lowperf",  "Trigger Low-Perf Cleanup", function() cleanup_unused_structures()       end, nil)
end

tm.players.OnPlayerJoined.add(on_player_joined)

-- Main update
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

    -- Do the cleanup loop
    cleanup_structures_loop()

    -- FPS based stuff
    local did_cleanup = false

    if current_fps <= CONFIG.critical_fps and avg_fps <= CONFIG.critical_avg_fps then
        log(string.format("CRITICAL LAG  %.1f fps (avg %.1f)", current_fps, avg_fps))

        local total_removed = cleanup_all_structures()
        local large_removed = emergency_cleanup_large_builds()

        did_cleanup = (total_removed + large_removed > 0)

    elseif current_fps <= CONFIG.cleanup_at_fps and avg_fps <= CONFIG.cleanup_at_avg_fps then
        if not state.player_just_joined then
            log(string.format("Low perf  %.1f fps (avg %.1f), cleaning", current_fps, avg_fps))
            did_cleanup = cleanup_unused_structures()
        end
    end

    -- Physics timescale smoothing
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

    -- Update admin UI
    for _, pid in ipairs(admin_player_ids) do
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