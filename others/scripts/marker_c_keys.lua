-- Keybindings:
-- Hold c       : Create new chapter (0.5s hold)
-- Tap c        : Hint "Hold to create"
-- Tap y        : Undo last chapter
-- Tap Shift+y  : Redo last undo
-- Hold y       : Reset/Clear ALL chapters (2.0s hold)
-- Tap Shift+c  : Toggle between Default Video Chapters and Custom .chapters file

local use_script = true

if use_script then
	local mp = require 'mp'
	local msg = require 'mp.msg'
	local utils = require 'mp.utils'

	-- Configuration
	local hold_threshold = 0.5       -- Time to hold 'c' to Create
	local reset_hold_threshold = 2.0 -- Time to hold 'y' to Reset All

	-- Script State
	local chapters = {}
	local original_chapters = {}
	local chapter_history = {}
	local redo_stack = {} 
	local key_down_time = {}
	local key_hold_action_triggered = {}
	local delay_timers = {}
	
	-- Mode state: false = Default, true = Custom (.chapters file)
	local custom_mode_active = false 

	-- Helper functions
	local function format_time(seconds)
		if not seconds then return "00:00:00" end
		local h = math.floor(seconds / 3600)
		local m = math.floor((seconds % 3600) / 60)
		local s = math.floor(seconds % 60)
		return string.format("%02d:%02d:%02d", h, m, s)
	end

	local function table_size(T)
		local count = 0
		for _ in pairs(T) do count = count + 1 end
		return count
	end

	local function get_chapter_filepath()
		local path = mp.get_property("path")
		if not path then return nil end
		local dir, name = utils.split_path(path)
		local base = name:match("(.+)%..+$") or name
		return utils.join_path(dir, base .. ".chapters")
	end

	local function apply_chapters()
		local combined = {}
		for num, time in pairs(chapters) do
			table.insert(combined, { title = tostring(num), time = time })
		end
		table.sort(combined, function(a, b) return a.time < b.time end)
		mp.set_property_native("chapter-list", combined)
	end
	
	local function get_sorted_chapters()
		local sorted = {}
		for num, time in pairs(chapters) do
			table.insert(sorted, { num = num, time = time })
		end
		table.sort(sorted, function(a, b) return a.time < b.time end)
		return sorted
	end
	
	local function internal_load_from_file()
		local filename = get_chapter_filepath()
		if not filename then return false end
		
		local f = io.open(filename, "r")
		if not f then return false end 

		chapters = {}
		chapter_history = {}
		redo_stack = {} 

		for line in f:lines() do
			local num, pos = line:match("(%d+)%s*=%s*([%d%.]+)")
			if num and pos then
				num = tonumber(num)
				chapters[num] = tonumber(pos)
				table.insert(chapter_history, num)
			end
		end
		f:close()
		return true
	end

	local function save_chapters()
		if not custom_mode_active then return end 
		
		local filename = get_chapter_filepath()
		if not filename then return end

		local f, err = io.open(filename, "w")
		if not f then
			mp.osd_message("Error saving: " .. tostring(err))
			return
		end

		local sorted_to_save = get_sorted_chapters()
		for _, chapter in ipairs(sorted_to_save) do
			f:write(string.format("%d=%.6f\n", chapter.num, chapter.time))
		end
		f:close()
		
		msg.info("Chapters saved to " .. filename)
	end

	local function ensure_custom_mode_synced()
		if custom_mode_active then return end 

		local loaded = internal_load_from_file()
		if loaded then
			msg.info("Existing chapter file loaded.")
		else
			chapters = {}
			chapter_history = {}
			redo_stack = {}
		end
		custom_mode_active = true
	end

	local function create_new_chapter()
		ensure_custom_mode_synced()
		
		redo_stack = {} 
		
		local pos = mp.get_property_number("time-pos")
		if not pos then return end

		if table_size(chapters) == 0 and pos > 0.1 then
			chapters[0] = 0
			table.insert(chapter_history, 0)
		end

		local next_num = 0
		for k in pairs(chapters) do
			next_num = math.max(next_num, k)
		end
		next_num = next_num + 1

		chapters[next_num] = pos
		table.insert(chapter_history, next_num)
		
		msg.info("Chapter " .. next_num .. " set")
		mp.osd_message(string.format("Chapter %d set at %s", next_num, format_time(pos)))
		
		apply_chapters()
		save_chapters() 
	end

	local function undo_last_chapter()
		ensure_custom_mode_synced()

		if #chapter_history == 0 then
			mp.osd_message("Nothing to Undo")
			return
		end
		
		local last_id = table.remove(chapter_history)
		local last_time = chapters[last_id]
		
		table.insert(redo_stack, { id = last_id, time = last_time })
		
		chapters[last_id] = nil
		
		apply_chapters()
		save_chapters()
		mp.osd_message("Undo: Chapter " .. last_id)
	end

	local function redo_last_chapter()
		ensure_custom_mode_synced()
		
		if #redo_stack == 0 then
			mp.osd_message("Nothing to Redo")
			return
		end
		
		local item = table.remove(redo_stack)
		
		chapters[item.id] = item.time
		table.insert(chapter_history, item.id)
		
		apply_chapters()
		save_chapters()
		mp.osd_message("Redo: Chapter " .. item.id)
	end

	local function reset_all_chapters()
		custom_mode_active = true
		chapters = {}
		chapter_history = {}
		redo_stack = {}
		apply_chapters()
		save_chapters() 
		mp.osd_message("All chapters cleared")
	end

	local function load_custom_chapters_ui()
		local loaded = internal_load_from_file()
		custom_mode_active = true
		apply_chapters()
		if loaded then
			mp.osd_message("Loaded Custom Chapters")
		else
			mp.osd_message("New Chapter File Started")
		end
	end

	local function restore_default_chapters()
		custom_mode_active = false
		mp.set_property_native("chapter-list", original_chapters)
		mp.osd_message("Default Chapters")
	end

	local function toggle_mode()
		if custom_mode_active then
			restore_default_chapters()
		else
			load_custom_chapters_ui()
		end
	end

	-- Key handlers

	-- "c": Create Chapter (Hold)
	local function handle_c_key(event)
		local key_id = "c_key"
		if event.event == "down" then
			key_down_time[key_id] = mp.get_time()
			key_hold_action_triggered[key_id] = false
			if delay_timers[key_id] then delay_timers[key_id]:kill() end
			delay_timers[key_id] = mp.add_timeout(hold_threshold, function()
				key_hold_action_triggered[key_id] = true
				create_new_chapter()
				delay_timers[key_id] = nil
			end)
		elseif event.event == "up" then
			if delay_timers[key_id] then delay_timers[key_id]:kill(); delay_timers[key_id] = nil end
			if not key_hold_action_triggered[key_id] then
				mp.osd_message("Hold 'c' to create chapter")
			end
			key_down_time[key_id], key_hold_action_triggered[key_id] = nil, nil
		end
	end

	-- "y": Undo (Tap) / Reset All (Hold)
	local function handle_y_key(event)
		local key_id = "y_key"
		if event.event == "down" then
			key_down_time[key_id] = mp.get_time()
			key_hold_action_triggered[key_id] = false
			if delay_timers[key_id] then delay_timers[key_id]:kill() end
			
			-- Uses the specific reset threshold (2.0s)
			delay_timers[key_id] = mp.add_timeout(reset_hold_threshold, function()
				key_hold_action_triggered[key_id] = true
				reset_all_chapters()
				delay_timers[key_id] = nil
			end)
		elseif event.event == "up" then
			if delay_timers[key_id] then delay_timers[key_id]:kill(); delay_timers[key_id] = nil end
			if not key_hold_action_triggered[key_id] then
				undo_last_chapter()
			end
			key_down_time[key_id], key_hold_action_triggered[key_id] = nil, nil
		end
	end

	local function on_file_load()
		chapters = {}
		chapter_history = {}
		redo_stack = {}
		custom_mode_active = false
		key_down_time, key_hold_action_triggered, delay_timers = {}, {}, {}
		
		original_chapters = mp.get_property_native("chapter-list") or {}
		
		if #original_chapters > 0 then
			msg.info("Default chapters detected. Using them.")
		else
			if internal_load_from_file() then
				custom_mode_active = true
				apply_chapters()
				-- msg.info("No default chapters. Auto-loaded custom file.")
				-- mp.osd_message("Auto-loaded Custom Chapters")
			end
		end
	end

	mp.register_event("file-loaded", on_file_load)
	
	mp.add_forced_key_binding("c", "chapter-create-key", handle_c_key, { complex = true })
	mp.add_forced_key_binding("y", "chapter-undo-reset", handle_y_key, { complex = true })
	mp.add_forced_key_binding("Y", "chapter-redo", redo_last_chapter) -- Shift+y
	mp.add_forced_key_binding("C", "chapter-file-toggle", toggle_mode) -- Shift+c
end