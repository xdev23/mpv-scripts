-- Set to true to enable the script, false to disable it
local use_script = true

if use_script then
	local utils = require 'mp.utils'
	local msg = require 'mp.msg'

	-- OFFSET ADJUSTMENT SEC (Ctrl+r / Ctrl+t)
	local offset_step = 0.1

	-- NETWORK / PIPES
	local pipe_name_base = "mpv_ipc_sync_" 
	local max_leader_ids = 5

	-- TIMING & PERFORMANCE
	local sync_rate = 0.05            
	local leader_alive_rate = 0.1     
	local leader_timeout = 0.2        
	local follower_alive = 1.0        
	local follower_timeout = 4.0      
	local long_press_threshold = 0.5  


	-- PLATFORM
	local is_windows = (package.config:sub(1,1) == '\\')
	local ipc_root = is_windows and "\\\\.\\pipe\\" or "/tmp/"


	local role = "none" 
	local my_id = nil 
	local leader_id = 1 
	local my_socket_path = nil
	local my_assigned_id = "?" 

	-- LEADER STATE
	local registered_followers = {} 
	local follower_id_map = {}      
	local leader_allow_control = false 
	local follower_is_locked = true    

	-- TIMERS & SYNC LOCKS
	local heartbeat_timer = nil
	local timeout_timer = nil
	local broadcast_timer = nil
	local follower_cleanup_timer = nil
	local w_start_time = 0
	local e_start_time = 0
	local last_leader_contact = 0 
	
	-- Drag Debouncing & Loop Prevention
	local follower_outbound_lock = 0 
	local follower_inbound_lock = 0  
	local follower_debounce_timer = nil

	-- MEMORY
	local sequence_id = 0
	local last_seq_id = -1
	local known_offsets = {} 
	local my_saved_offset = nil 
	local original_offset = nil 

	-- CHANGE DETECTION (LEADER)
	local prev_time = 0
	local prev_pause = true
	local prev_speed = 1
	local prev_dir = "forward"
	local last_packet_time = 0 

	--  LOCKDOWN LIST 
	local blocked_keys = {
		"LEFT", "RIGHT", "UP", "DOWN",
		"Shift+LEFT", "Shift+RIGHT", "Shift+UP", "Shift+DOWN",
		"Ctrl+LEFT", "Ctrl+RIGHT",
		"MBTN_LEFT", "MBTN_LEFT_DBL", "MBTN_RIGHT", "MBTN_BACK", "MBTN_FORWARD",
		"WHEEL_UP", "WHEEL_DOWN", "WHEEL_LEFT", "WHEEL_RIGHT",
		"SPACE", "p", "ENTER", "[", "]", "BS", ".", ",",
		"m", "9", "0", "/", "*", "v" 
	}

	--  HELPERS 
	function get_leader_pipe(id) return ipc_root .. pipe_name_base .. "leader_" .. tostring(id) end

	function get_follower_pipe()
		local r = math.random(1000, 9999)
		return ipc_root .. pipe_name_base .. "follower_" .. tostring(os.time()) .. "_" .. tostring(r)
	end

	function get_follower_count()
		local count = 0
		for _ in pairs(registered_followers) do count = count + 1 end
		return count
	end

	function socket_exists(path)
		local f = io.open(path, "r")
		if f then f:close(); return true end
		return false
	end

	function get_active_leader()
		for i = 1, max_leader_ids do
			if socket_exists(get_leader_pipe(i)) then return i end
		end
		return nil
	end

	--  IPC SENDER 
	function send_raw_json(target_path, json_table)
		local payload = utils.format_json(json_table) .. "\n"
		if is_windows then
			local f = io.open(target_path, "w")
			if f then f:write(payload); f:flush(); f:close() end
		else
			mp.command_native_async({
				name = "subprocess", args = {"socat", "-", target_path},
				stdin_data = payload, playback_only = false, capture_stdout = true
			}, function() end)
		end
	end

	function send_script_message(target_path, command, ...)
		local args = {...}
		local message = { command = { "script-message", command } }
		for _, v in ipairs(args) do table.insert(message.command, tostring(v)) end
		send_raw_json(target_path, message)
	end

	--  LOCKDOWN & UI 
	function lock_controls()
		local function notify() mp.osd_message("LOCKED (Leader disabled controls)", 0.5) end
		for _, key in ipairs(blocked_keys) do mp.add_forced_key_binding(key, "blocked_"..key, notify) end
		mp.commandv("script-message", "osc-visibility", "never")
		mp.set_property_bool("osc", false)
		follower_is_locked = true
	end
	
	function unlock_controls()
		for _, key in ipairs(blocked_keys) do mp.remove_key_binding("blocked_"..key) end
		mp.set_property_bool("osc", true)
		mp.commandv("script-message", "osc-visibility", "auto")
		follower_is_locked = false
		follower_outbound_lock = mp.get_time() + 0.5 
	end

	function update_leader_title()
		if role ~= "leader" then return end
		local fname = mp.get_property("filename") or ""
		local title = string.format("LEADER %s (Followers: %d) - %s", tostring(my_id), get_follower_count(), fname)
		mp.set_property("title", title)
		mp.set_property("force-media-title", title)
	end

	function update_follower_title(latency_ms, offset_val)
		if role ~= "follower" then return end
		local fname = mp.get_property("filename") or ""
		local lat_str = latency_ms and string.format("%dms", latency_ms) or "?"
		local off_str = offset_val and string.format("%.2fs", offset_val) or "0s"
		
		local title = string.format("FOLLOWER %s (to Leader %s) (IPC: %s | Offset: %s) - %s", 
			tostring(my_assigned_id), tostring(leader_id), lat_str, off_str, fname)
			
		mp.set_property("title", title)
		mp.set_property("force-media-title", title)
	end


	--  LEADER LOGIC (SERVER) 


	function broadcast_state()
		if role ~= "leader" then return end

		local now = mp.get_time()
		local time = mp.get_property_number("time-pos")
		local pause = mp.get_property_native("pause")
		local speed = mp.get_property_number("speed") or 1
		local direction = mp.get_property("play-direction") or "forward"
		
		if time then
			local changed = false
			
			if pause ~= prev_pause then changed = true end
			if math.abs(speed - prev_speed) > 0.01 then changed = true end
			if direction ~= prev_dir then changed = true end
			
			if not prev_pause then
				local expected = prev_time + (sync_rate * prev_speed * (prev_dir == "forward" and 1 or -1))
				if math.abs(time - expected) > 0.5 then changed = true end
			end

			prev_time = time; prev_pause = pause; prev_speed = speed; prev_dir = direction

			local time_since_last = now - last_packet_time
			local need_heartbeat = time_since_last >= leader_alive_rate

			if changed or need_heartbeat then
				if changed then sequence_id = sequence_id + 1 end
				last_packet_time = now

				local state = { 
					seq = sequence_id, 
					time = time, 
					pause = pause, 
					speed = speed, 
					direction = direction, 
					memory = known_offsets,
					leader_fname = mp.get_property("filename") or "unknown",
					allow_control = leader_allow_control 
				}
				local json_state = utils.format_json(state)

				for socket_path, _ in pairs(registered_followers) do
					send_script_message(socket_path, "sync-update", json_state)
				end
			end
		end
	end

	function check_follower_timeouts()
		if role ~= "leader" then return end
		local now = mp.get_time()
		local changed = false
		
		for socket, last_seen in pairs(registered_followers) do
			if (now - last_seen) > follower_timeout then
				registered_followers[socket] = nil
				follower_id_map[socket] = nil
				mp.osd_message("Follower Exited", 2)
				changed = true
			end
		end
		
		if changed then update_leader_title() end
	end

	function get_lowest_available_id()
		local used = {}
		for _, id in pairs(follower_id_map) do used[id] = true end
		local i = 1
		while true do
			if not used[i] then return i end
			i = i + 1
		end
	end

	function leader_receive_register(follower_path)
		if not follower_path then return end
		
		local now = mp.get_time()
		local is_new = not registered_followers[follower_path]
		
		registered_followers[follower_path] = now
		
		if is_new then
			local this_id = get_lowest_available_id()
			follower_id_map[follower_path] = this_id
			
			send_script_message(follower_path, "assign_id", tostring(this_id))
			
			mp.osd_message("Follower " .. this_id .. " Joined", 2)
			update_leader_title()
			
			prev_time = 0 
			broadcast_state()
		else
			local existing_id = follower_id_map[follower_path]
			if existing_id then
				send_script_message(follower_path, "assign_id", tostring(existing_id))
			end
		end
	end

	function leader_receive_cmd(cmd, arg1, arg2, arg3, arg4)
		if cmd == "REGISTER" and arg1 and arg2 then
			known_offsets[arg1] = tonumber(arg2)
			sequence_id = sequence_id + 1
			last_packet_time = 0 
			broadcast_state()
		elseif cmd == "RESTORE" and arg1 and arg2 and arg3 then
			local fname = arg1
			local jump_to = tonumber(arg3)
			known_offsets[fname] = tonumber(arg2)
			if jump_to then
				mp.set_property_number("time-pos", jump_to)
				mp.osd_message("Session Restored", 2)
				sequence_id = sequence_id + 1
				last_packet_time = 0
				broadcast_state()
			end
		elseif cmd == "RESET" and arg1 then
			known_offsets[arg1] = nil
			sequence_id = sequence_id + 1
			last_packet_time = 0
			broadcast_state()
			
		elseif cmd == "FOLLOWER_STATE_UPDATE" and arg1 and arg2 then
			if not leader_allow_control then return end 
			
			local new_time = tonumber(arg1)
			local new_pause = (arg2 == "true")
			local new_speed = tonumber(arg3)
			local new_dir = arg4

			local leader_time = mp.get_property_number("time-pos") or 0
			if new_time and math.abs(leader_time - new_time) > 0.1 then
				mp.set_property_number("time-pos", new_time)
			end
			
			mp.set_property_native("pause", new_pause)
			if new_speed then mp.set_property_number("speed", new_speed) end
			if new_dir then mp.set_property("play-direction", new_dir) end
			
			mp.osd_message("Follower Synced Pos", 1.5)
			
			sequence_id = sequence_id + 1
			last_packet_time = 0
			broadcast_state()
		end
	end

	function broadcast_kill_to_followers()
		if role == "leader" then
			for socket_path, _ in pairs(registered_followers) do
				local message = { command = { "script-message", "sync-exit" } }
				send_raw_json(socket_path, message)
			end
		end
	end

	function start_leader(id)
		my_saved_offset = nil; original_offset = nil
		my_id = id; role = "leader"
		my_socket_path = get_leader_pipe(id)
		registered_followers = {}; follower_id_map = {}
		sequence_id = 0
		last_packet_time = 0
		leader_allow_control = false 
		
		mp.set_property("input-ipc-server", my_socket_path)
		mp.register_script_message("register_follower", leader_receive_register)
		mp.register_script_message("unregister_follower", leader_receive_unregister)
		mp.register_script_message("client_cmd", leader_receive_cmd)
		
		if broadcast_timer then broadcast_timer:kill() end
		broadcast_timer = mp.add_periodic_timer(sync_rate, broadcast_state)
		
		if follower_cleanup_timer then follower_cleanup_timer:kill() end
		follower_cleanup_timer = mp.add_periodic_timer(1.0, check_follower_timeouts)
		
		mp.osd_message("LEADER " .. my_id .. " Started", 2)
		update_leader_title()
	end

	function stop_leader()
		if broadcast_timer then broadcast_timer:kill() end
		if follower_cleanup_timer then follower_cleanup_timer:kill() end
		mp.set_property("input-ipc-server", "")
		mp.unregister_script_message("register_follower")
		mp.unregister_script_message("unregister_follower")
		mp.unregister_script_message("client_cmd")
		role = "none"; my_id = nil
		mp.osd_message("LEADER Stopped", 2)
		
		local fname = mp.get_property("filename") or ""
		mp.set_property("force-media-title", fname)
		mp.set_property("title", fname)
	end


	--  FOLLOWER LOGIC (CLIENT) 

	function queue_follower_sync()
		if role ~= "follower" or follower_is_locked or not my_saved_offset then return end
		
		if mp.get_time() < follower_outbound_lock then return end

		follower_inbound_lock = mp.get_time() + 1.0

		if follower_debounce_timer then follower_debounce_timer:kill() end
		
		follower_debounce_timer = mp.add_timeout(0.2, function()
			local time = mp.get_property_number("time-pos")
			local pause = mp.get_property_native("pause")
			local speed = mp.get_property_number("speed") or 1
			local direction = mp.get_property("play-direction") or "forward"

			if not time then return end

			local target = get_leader_pipe(leader_id)
			local l_time = time - my_saved_offset
			if l_time < 0 then l_time = 0 end
			
			send_script_message(target, "client_cmd", "FOLLOWER_STATE_UPDATE", tostring(l_time), tostring(pause), tostring(speed), direction)
		end)
	end

	function check_alive_status()
		if role ~= "follower" then return end
		if (mp.get_time() - last_leader_contact) > leader_timeout then
			if not mp.get_property_native("pause") then
				mp.set_property_native("pause", true)
				mp.osd_message("Sync: Leader Timeout", 5)
			end
		end
	end

	function follower_receive_exit()
		if role == "follower" then mp.command("quit-watch-later") end
	end
    
    -- Function to handle clean disconnect when leader terminates
	function follower_receive_terminate()
		if role == "follower" then 
            stop_follower()
            mp.osd_message("Leader terminated the session. Disconnected.", 3)
        end
	end

	function follower_receive_id(id_str)
		if role == "follower" and id_str then
			my_assigned_id = id_str
			local latency = math.floor((mp.get_time() - last_leader_contact) * 1000)
			update_follower_title(latency, my_saved_offset)
		end
	end

	function follower_receive_update(json_str)
		if role ~= "follower" then return end
		
		local now = mp.get_time()
		local latency = math.floor((now - last_leader_contact) * 1000)
		last_leader_contact = now
		
		if math.random() > 0.8 then update_follower_title(latency, my_saved_offset) end

		local state = utils.parse_json(json_str)
		if not state then return end
		
		local seq = state.seq or 0
		local l_time = state.time
		local l_paused = state.pause
		local l_speed = state.speed
		local l_direction = state.direction or "forward"
		local leader_fname = state.leader_fname or "unknown" 
		local remote_mem = state.memory or {}
		local l_allow_control = state.allow_control or false 
		local my_fname = mp.get_property("filename") or "unknown"
		local leader_knows_me = remote_mem[my_fname]
		
		if seq < last_seq_id then last_seq_id = -1 end

		if l_allow_control and follower_is_locked then
			unlock_controls()
			mp.osd_message("Sync: Leader ENABLED your controls", 2)
		elseif not l_allow_control and not follower_is_locked then
			lock_controls()
			mp.osd_message("Sync: Leader DISABLED your controls", 2)
		end

		if not leader_knows_me then
			if my_saved_offset then
				local my_curr = mp.get_property_number("time-pos") or 0
				local restore_time = my_curr - my_saved_offset
				if restore_time < 0 then restore_time = 0 end
				local target = get_leader_pipe(leader_id)
				send_script_message(target, "client_cmd", "RESTORE", my_fname, my_saved_offset, restore_time)
				mp.osd_message("Restoring...", 2)
				return
			else
				local my_time = mp.get_property_number("time-pos")
				if my_time and l_time then
					if my_fname == leader_fname and my_fname ~= "unknown" then
						my_saved_offset = 0
						mp.osd_message("Matching Video: Exact Sync Enabled", 2)
					else
						my_saved_offset = my_time - l_time
					end
					original_offset = my_saved_offset
					
					follower_outbound_lock = mp.get_time() + 0.8
					mp.set_property_native("pause", l_paused)
					mp.set_property_number("speed", l_speed)
					mp.set_property("play-direction", l_direction)
					
					local target = get_leader_pipe(leader_id)
					send_script_message(target, "client_cmd", "REGISTER", my_fname, my_saved_offset)
					mp.osd_message("Connected", 1)
					update_follower_title(latency, my_saved_offset)
					return
				end
			end
		else
			my_saved_offset = leader_knows_me
			if not original_offset then original_offset = my_saved_offset end
		end
		
		if my_saved_offset then
			if mp.get_time() > follower_inbound_lock then
				local actually_applied_change = false
				
				local cur_dir = mp.get_property("play-direction")
				if cur_dir ~= l_direction then 
					mp.set_property("play-direction", l_direction) 
					actually_applied_change = true
				end
				
				local current_speed = mp.get_property_number("speed")
				if math.abs(current_speed - l_speed) > 0.01 then 
					mp.set_property_number("speed", l_speed) 
					actually_applied_change = true
				end
				
				local current_pause = mp.get_property_native("pause")
				if current_pause ~= l_paused then 
					mp.set_property_native("pause", l_paused) 
					actually_applied_change = true
				end

				if seq > last_seq_id then
					last_seq_id = seq
					local target = l_time + my_saved_offset
					if target < 0 then target = 0 end
					
					local current_time = mp.get_property_number("time-pos") or 0
					if math.abs(current_time - target) > 0.2 then
						mp.set_property_number("time-pos", target) 
						actually_applied_change = true
					end
				end
				
				if actually_applied_change then
					follower_outbound_lock = mp.get_time() + 0.8
				end
			else
				if seq > last_seq_id then last_seq_id = seq end
			end
		end
	end

	function follower_send_presence()
		if role == "follower" and leader_id and my_socket_path then
			local target = get_leader_pipe(leader_id)
			send_script_message(target, "register_follower", my_socket_path)
		end
	end

	function start_follower(target_id)
		if role == "leader" then return end
		if role == "follower" then stop_follower() end
		
		my_saved_offset = nil; original_offset = nil
		leader_id = target_id or leader_id or 1
		role = "follower"
		last_seq_id = -1
		
		follower_outbound_lock = mp.get_time() + 1.0
		follower_inbound_lock = 0
		
		my_socket_path = get_follower_pipe()
		mp.set_property("input-ipc-server", my_socket_path)
		
		mp.register_script_message("sync-update", follower_receive_update)
		mp.register_script_message("sync-exit", follower_receive_exit)
        mp.register_script_message("sync-terminate", follower_receive_terminate)
		mp.register_script_message("assign_id", follower_receive_id)
		
		if heartbeat_timer then heartbeat_timer:kill() end
		heartbeat_timer = mp.add_periodic_timer(follower_alive, follower_send_presence)
		
		if timeout_timer then timeout_timer:kill() end
		timeout_timer = mp.add_periodic_timer(0.1, check_alive_status)
		
		last_leader_contact = mp.get_time()
		follower_send_presence()
		
		lock_controls()
		
		mp.set_property("mute", "yes") 
		
		mp.osd_message("Sync: Connecting to Leader " .. leader_id .. "...", 2)
		update_follower_title(0, 0)
	end

	function stop_follower()
		if leader_id and my_socket_path then
			local target = get_leader_pipe(leader_id)
			send_script_message(target, "unregister_follower", my_socket_path)
		end

		role = "none"
		mp.set_property("input-ipc-server", "")
		mp.unregister_script_message("sync-update")
		mp.unregister_script_message("sync-exit")
        mp.unregister_script_message("sync-terminate")
		mp.unregister_script_message("assign_id")
		if heartbeat_timer then heartbeat_timer:kill() end
		if timeout_timer then timeout_timer:kill() end
		if follower_debounce_timer then follower_debounce_timer:kill() end
		
		unlock_controls()
		mp.set_property("mute", "no")
		mp.osd_message("Follower Stopped", 2)
		
		local fname = mp.get_property("filename") or ""
		mp.set_property("force-media-title", fname)
		mp.set_property("title", fname)
	end

	--  CONTROLS 

	function handle_w(table)
		if table.event == "down" then 
			w_start_time = mp.get_time()
		elseif table.event == "up" then
			if (mp.get_time() - w_start_time) < long_press_threshold then
				if role == "leader" then
					mp.osd_message("You are Leader " .. tostring(my_id), 1)
				elseif role == "follower" then
					mp.osd_message("Already a Follower", 1)
				else
					for i = 1, max_leader_ids do
						if not socket_exists(get_leader_pipe(i)) then
							start_leader(i)
							return
						end
					end
					mp.osd_message("All Leader IDs (1-"..max_leader_ids..") Taken", 2)
				end
			else
				if role == "leader" then stop_leader() end
			end
		end
	end

	function handle_e(table)
		if table.event == "down" then 
			e_start_time = mp.get_time()
		elseif table.event == "up" then
			if (mp.get_time() - e_start_time) < long_press_threshold then
				if role == "leader" then
					mp.osd_message("Cannot become Follower", 1)
				elseif role == "follower" then
					mp.osd_message("Connected to Leader " .. tostring(leader_id), 1)
				else
					local l_id = get_active_leader()
					if l_id then
						start_follower(l_id)
					else
						mp.osd_message("No Leader available to follow!", 2)
					end
				end
			else
				if role == "follower" then stop_follower() end
			end
		end
	end

	function cycle_leader()
		if role ~= "follower" and role ~= "none" then 
			mp.osd_message("Must be Follower or None to Cycle", 1)
			return
		end

		local start_search = (role == "follower") and (leader_id + 1) or 1
		local found_id = nil
		
		for i = start_search, max_leader_ids do
			if socket_exists(get_leader_pipe(i)) then found_id = i; break end
		end
		if not found_id then
			for i = 1, max_leader_ids do
				if socket_exists(get_leader_pipe(i)) then found_id = i; break end
			end
		end

		if found_id then
			if role == "follower" and found_id == leader_id then
				mp.osd_message("Already on the only active Leader", 2)
			else
				stop_follower()
				start_follower(found_id)
				mp.osd_message("Switched to Leader " .. found_id, 2)
			end
		else
			mp.osd_message("No Leaders Found", 1)
		end
	end

	function toggle_follower_control()
		if role == "leader" then
			leader_allow_control = not leader_allow_control
			local status = leader_allow_control and "ENABLED" or "DISABLED"
			mp.osd_message("Follower Controls: " .. status, 2)
			last_packet_time = 0 
			broadcast_state()
		else
			mp.osd_message("Only Leader can toggle Follower controls", 1)
		end
	end

	function force_reset()
		if role == "follower" then
			my_saved_offset = nil; original_offset = nil
			local my_fname = mp.get_property("filename") or "unknown"
			local target = get_leader_pipe(leader_id)
			send_script_message(target, "client_cmd", "RESET", my_fname)
			last_seq_id = -1
			mp.osd_message("Sync: RESET.", 2)
		end
	end

	function modify_offset(val)
		if role ~= "follower" then return end
		if not my_saved_offset then return end
		if not original_offset then original_offset = my_saved_offset end

		my_saved_offset = my_saved_offset + val
		local my_fname = mp.get_property("filename") or "unknown"
		local target = get_leader_pipe(leader_id)
		send_script_message(target, "client_cmd", "REGISTER", my_fname, my_saved_offset)
		
		local diff = my_saved_offset - original_offset
		local sign = (diff >= 0) and "+" or ""
		
		mp.osd_message(string.format("Offset: %.2f | Orig: %.2f | Diff: %s%.2f | Step: %.2f", 
			my_saved_offset, original_offset, sign, diff, math.abs(val)), 1)
	end
	
	-- Open a new MPV instance playing the exact same file
	function open_new_instance()
		if role == "leader" then
			local filepath = mp.get_property("path")
			if filepath then
				mp.commandv("run", "mpv", filepath)
				mp.osd_message("Opening new window...", 2)
			else
				mp.osd_message("No video playing to duplicate", 2)
			end
		else
			mp.osd_message("Only the Leader can spawn a new window", 1)
		end
	end

	function quit_all()
		if role == "leader" then
			broadcast_kill_to_followers()
			mp.command("quit-watch-later")
		else
			mp.osd_message("Only Leader can Quit All", 1)
		end
	end
    
    -- Function to terminate the session entirely
    function terminate_session()
        if role == "leader" then
            -- Tell followers to disconnect cleanly
            for socket_path, _ in pairs(registered_followers) do
                local message = { command = { "script-message", "sync-terminate" } }
                send_raw_json(socket_path, message)
            end
            
            -- Wiping the memory clears out the persistent offset issues
            known_offsets = {}
            
            -- Safely shut down leader 
            stop_leader()
            mp.osd_message("Session Terminated & Memory Cleared", 3)
        else
            mp.osd_message("Only Leader can terminate the session", 2)
        end
    end

	mp.add_key_binding("w", "sync_leader_key", handle_w, {complex=true})
	mp.add_key_binding("e", "sync_follower_key", handle_e, {complex=true})
	mp.add_key_binding("Ctrl+f", "sync_toggle_control", toggle_follower_control) 
	mp.add_key_binding("Ctrl+o", "sync_open_new", open_new_instance)
	mp.add_key_binding("Shift+e", "sync_reset", force_reset)
	mp.add_key_binding("Ctrl+e", "sync_cycle_leader", cycle_leader)
	mp.add_key_binding("Ctrl+Shift+w", "sync_quit_all", quit_all)
    mp.add_key_binding("Ctrl+Shift+t", "sync_terminate_session", terminate_session)
	mp.add_key_binding("Ctrl+r", "sync_offset_down", function() modify_offset(-offset_step) end, {repeatable=true})
	mp.add_key_binding("Ctrl+t", "sync_offset_up", function() modify_offset(offset_step) end, {repeatable=true})

	local last_known_leader_state = false
	mp.add_periodic_timer(2.0, function()
		if role == "none" then
			local active_l = get_active_leader()
			if active_l and not last_known_leader_state then
				mp.osd_message("Leader " .. active_l .. " detected! Press 'e' to join.", 4)
			end
			last_known_leader_state = (active_l ~= nil)
		else
			last_known_leader_state = true
		end
	end)

	mp.observe_property("pause", "bool", function() queue_follower_sync() end)
	mp.observe_property("speed", "number", function() queue_follower_sync() end)
	mp.observe_property("play-direction", "string", function() queue_follower_sync() end)
	mp.register_event("seek", function() queue_follower_sync() end)
end
