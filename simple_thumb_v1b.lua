-- Set to true to enable the script, false to disable it
local use_script = true

if use_script then

	local options = {
		max_height = 350,
		max_width = 350,
		overlay_id = 42,
		quit_after_inactivity = 0,
		hwdec = false,
		mpv_path = "mpv",
		
		-- Border Options
		use_border = true,
		border_width = 2,        -- Thickness of the border in pixels
		border_color = "FFFFFF", -- Border color in hex (RRGGBB)
		border_alpha = 255,      -- Opacity from 0 (transparent) to 255 (solid)

		-- Chapter Options
		show_chapter = true,
		use_background_for_thumbnail_chapter = true,
		chapter_bg_color = "FFFFFF", -- White background
		chapter_text_color = "000000", -- Black text
		chapter_font_size = 18
	}

	local mp = require 'mp'
	local opt = require 'mp.options'
	mp.utils = require "mp.utils"

	-- Positioning Configuration
	local use_fixed_preview_height = true    -- used for top and bottombar only, if false dynamic y offset is used
	local fixed_preview_y_offset = 90        -- Used for standard topbar/bottombar when fixed
	local dynamic_preview_y_offset = 60      -- Used for other layouts, or when use_fixed_preview_height is false

	local os_name = mp.get_property("platform") or "linux"
	if os_name:match("windows") or os_name:match("mingw") then os_name = "windows" end

	local unique = mp.utils.getpid()
	local socket_path = os_name == "windows" and ("hover_preview_" .. unique) or ("/tmp/hover_preview_" .. unique)
	local preview_dir = ""
	local preview_filepath = ""

	local mpv_path = options.mpv_path
	if mpv_path == "mpv" and os_name == "windows" then
		mpv_path = mp.get_property_native("user-data/frontend/process-path") or mpv_path
	end

	local spawned = false
	local disabled = false

	local effective_w, effective_h = options.max_width, options.max_height
	local real_w, real_h
	local is_preview_visible = false

	-- CUSTOM PREVIEW UI CONFIG
	local preview_x = 20
	local preview_y = 20
	local showing = false
	local target_hover_time = -1
	local is_topbar = false -- Tracks globally if we are on the top bar

	local border_overlay = mp.create_osd_overlay("ass-events")

	-- Helper to convert standard Hex RGB and Alpha to ASS format
	local function get_ass_color_and_alpha(hex, alpha)
		hex = hex:gsub("#", "")
		if #hex ~= 6 then hex = "FFFFFF" end
		local r = hex:sub(1,2)
		local g = hex:sub(3,4)
		local b = hex:sub(5,6)
		local a = string.format("%02X", 255 - math.max(0, math.min(255, alpha)))
		return string.format("&H%s%s%s&", b, g, r), string.format("&H%s&", a)
	end

	-- Helper to draw an ASS filled rectangle
	local function ass_rect(x, y, rw, rh, c, a)
		x, y, rw, rh = math.floor(x), math.floor(y), math.floor(rw), math.floor(rh)
		return string.format("{\\an7\\pos(%d,%d)\\bord0\\1c%s\\1a%s\\p1}m 0 0 l %d 0 l %d %d l 0 %d x{\\p0}",
			x, y, c, a, rw, rw, rh, rh)
	end

	-- Helper to get the chapter title at a specific time
	local function get_chapter_at_time(time)
		local chapters = mp.get_property_native("chapter-list")
		if not chapters or #chapters == 0 then return nil end
		
		local current_chap = nil
		for i, chap in ipairs(chapters) do
			if time >= chap.time then
				current_chap = chap.title
			else
				break
			end
		end
		
		-- Fallback to first chapter if hovering before it technically starts
		if not current_chap and time < chapters[1].time then
			current_chap = chapters[1].title
		end
		return current_chap
	end

	-- Helper to estimate text width and truncate with "..." if it overflows
	local function truncate_text(text, max_w, font_size)
		if not text or text == "" then return "" end
		-- Rough estimate: average character width is ~55% of the font size
		local char_w = font_size * 0.55
		local max_chars = math.floor(max_w / char_w)
		
		if #text > max_chars then
			return text:sub(1, math.max(1, max_chars - 3)) .. "..."
		end
		return text
	end

	local function subprocess(args, async, callback)
		callback = callback or function() end
		if async then
			return mp.command_native_async({name = "subprocess", playback_only = true, args = args}, callback)
		else
			return mp.command_native({name = "subprocess", playback_only = false, capture_stdout = true, args = args})
		end
	end

	local function setup_preview_dir()
		local path = mp.get_property("path")
		local is_network = mp.get_property_native("demuxer-via-network")
		
		if is_network or not path then
			preview_dir = (os_name == "windows") and (os.getenv("TEMP") .. "\\hover_preview") or "/tmp/hover_preview"
		else
			local dir, _ = mp.utils.split_path(path)
			preview_dir = mp.utils.join_path(dir, ".hover_preview_tmp")
		end
		
		if os_name == "windows" then
			mp.command_native({name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true, args = {"cmd", "/C", "mkdir", preview_dir}})
		else
			mp.command_native({name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true, args = {"mkdir", "-p", preview_dir}})
		end
		
		preview_filepath = mp.utils.join_path(preview_dir, "preview_" .. unique .. ".out")
	end

	local function move_file(from, to)
		if os_name == "windows" then
			os.remove(to)
		end
		os.rename(from, to)
	end

	local function remove_preview_files()
		if preview_filepath ~= "" then
			os.remove(preview_filepath)
			os.remove(preview_filepath .. ".bgra")
			os.remove(preview_filepath .. ".tmp")
		end
	end

	local function calc_dimensions()
		local width = mp.get_property_native("video-out-params/dw")
		local height = mp.get_property_native("video-out-params/dh")
		if not width or not height then return false end

		if width / height > options.max_width / options.max_height then
			effective_w = math.floor(options.max_width + 0.5)
			effective_h = math.floor(height / width * effective_w + 0.5)
		else
			effective_h = math.floor(options.max_height + 0.5)
			effective_w = math.floor(width / height * effective_h + 0.5)
		end
		return true
	end

	local activity_timer
	local function quit()
		activity_timer:kill()
		if is_preview_visible then
			activity_timer:resume()
			return
		end
		if spawned then
			if os_name == "windows" then
				local f = io.open("\\\\.\\pipe\\" .. socket_path, "r+b")
				if f then f:write("quit\n"); f:flush(); f:close() end
			else
				subprocess({"/usr/bin/env", "sh", "-c", "echo 'quit' | socat - " .. socket_path})
			end
		end
		spawned = false
		real_w, real_h = nil, nil
	end

	activity_timer = mp.add_timeout(options.quit_after_inactivity, quit)
	activity_timer:kill()

	local function spawn(time)
		if disabled or mp.get_property("path") == nil then return end

		if options.quit_after_inactivity > 0 then activity_timer:resume() end

		remove_preview_files()

		local args = {
			mpv_path, "--no-config", "--msg-level=all=no", "--idle", "--pause", "--keep-open=always",
			"--really-quiet", "--no-terminal", "--load-scripts=no", "--osc=no", "--ytdl=no",
			"--vid=auto", "--no-sub", "--no-audio", "--start="..time, "--hr-seek=yes",
			"--ytdl-format=worst", "--demuxer-readahead-secs=0", "--demuxer-max-bytes=128KiB",
			"--vd-lavc-skiploopfilter=all", "--vd-lavc-software-fallback=1", "--vd-lavc-fast",
			"--hwdec="..(options.hwdec and "auto" or "no"),
			"--vf=scale=w="..effective_w..":h="..effective_h..",pad=w="..effective_w..":h="..effective_h..":x=-1:y=-1,format=bgra",
			"--sws-scaler=fast-bilinear", "--ovc=rawvideo", "--of=image2", "--ofopts=update=1",
			"--o="..preview_filepath, "--input-ipc-server="..socket_path, "--", mp.get_property("path")
		}

		spawned = true

		subprocess(args, true, function(success, result)
			if not success or (result.status ~= 0 and result.status ~= -2) then
				spawned = false
				mp.msg.error("hover_preview: background mpv process failed to start.")
			end
		end)
	end

	local ipc_file = nil
	local ipc_bytes = 0
	local function run_seek(time)
		if not spawned then return end
		local command = "async seek " .. time .. " absolute\n"
		
		if os_name == "windows" then
			if ipc_file and ipc_bytes + #command >= 4096 then
				ipc_file:close()
				ipc_file = nil
				ipc_bytes = 0
			end
			if not ipc_file then ipc_file = io.open("\\\\.\\pipe\\" .. socket_path, "r+b") end
			if ipc_file then
				ipc_bytes = ipc_file:seek("end") or 0
				ipc_file:write(command)
				ipc_file:flush()
			end
		else
			subprocess({"/usr/bin/env", "sh", "-c", "echo '" .. command .. "' | socat - " .. socket_path})
		end
	end

	local function draw(w, h)
		if not w or not is_preview_visible then return end
		
		-- Draw Image Overlay
		mp.command_native_async({"overlay-add", options.overlay_id, preview_x, preview_y, preview_filepath..".bgra", 0, "bgra", w, h, (4*w)}, function() end)

		-- Draw Border and Chapter overlays
		if border_overlay then
			local osd = mp.get_property_native("osd-dimensions")
			if osd then
				border_overlay.res_x = osd.w
				border_overlay.res_y = osd.h
				
				local ass_data = ""
				local bw = options.use_border and options.border_width or 0
				
				-- 1. Assemble strictly wrapped Image Border
				if options.use_border then
					local b_color, b_alpha = get_ass_color_and_alpha(options.border_color, options.border_alpha)
					
					local top_bar   = ass_rect(preview_x - bw, preview_y - bw, w + (bw * 2), bw, b_color, b_alpha)
					local bot_bar   = ass_rect(preview_x - bw, preview_y + h, w + (bw * 2), bw, b_color, b_alpha)
					local left_bar  = ass_rect(preview_x - bw, preview_y, bw, h, b_color, b_alpha)
					local right_bar = ass_rect(preview_x + w, preview_y, bw, h, b_color, b_alpha)
					
					ass_data = top_bar .. "\n" .. bot_bar .. "\n" .. left_bar .. "\n" .. right_bar
				end

				-- 2. Assemble Chapter Text & Background
				if options.show_chapter and target_hover_time >= 0 then
					local chap_title = get_chapter_at_time(target_hover_time)
					if chap_title and chap_title ~= "" then
						local fs = options.chapter_font_size
						-- Truncate to fit the image width
						local chap_text = truncate_text(chap_title, w - 10, fs)
						local chap_h = fs + 8
						
						local chap_y
						if is_topbar then
							-- Place ABOVE the image (and above the top border)
							chap_y = preview_y - chap_h - bw
						else
							-- Place BELOW the image (and below the bottom border)
							chap_y = preview_y + h + bw 
						end
						
						-- Draw Background if enabled
						if options.use_background_for_thumbnail_chapter then
							local bg_c, bg_a = get_ass_color_and_alpha(options.chapter_bg_color, 255)
							local bg_rect = ass_rect(preview_x - bw, chap_y, w + (bw * 2), chap_h, bg_c, bg_a)
							if ass_data ~= "" then ass_data = ass_data .. "\n" end
							ass_data = ass_data .. bg_rect
						end
						
						local txt_c, txt_a = get_ass_color_and_alpha(options.chapter_text_color, 255)
						local txt_x = preview_x + (w / 2)
						local txt_y = chap_y + (chap_h / 2)
						
						-- Fallback styling: If background is off, add a white border/shadow so black text doesn't vanish into a dark video
						local text_style = options.use_background_for_thumbnail_chapter 
							and "\\bord0\\shad0" 
							or "\\bord1\\shad1\\3c&HFFFFFF&"
						
						-- Render text
						local text_line = string.format("{\\an5\\pos(%d,%d)\\1c%s\\1a%s\\fs%d%s\\q2}%s", 
							txt_x, txt_y, txt_c, txt_a, fs, text_style, chap_text)
							
						if ass_data ~= "" then ass_data = ass_data .. "\n" end
						ass_data = ass_data .. text_line
					end
				end

				-- Update overlay if there is anything to draw, otherwise hide
				if ass_data ~= "" then
					border_overlay.data = ass_data
					border_overlay:update()
				else
					border_overlay:remove()
				end
			end
		end
	end

	local file_timer
	local function check_new_preview()
		local tmp = preview_filepath..".tmp"
		move_file(preview_filepath, tmp)
		
		local finfo = mp.utils.file_info(tmp)
		if not finfo then return false end
		
		local expected_pixels = effective_w * effective_h
		if finfo.size / 4 == expected_pixels then
			move_file(tmp, preview_filepath..".bgra")
			real_w, real_h = effective_w, effective_h
			return true
		end
		return false
	end

	file_timer = mp.add_periodic_timer(1/60, function()
		if check_new_preview() then draw(real_w, real_h) end
	end)
	file_timer:kill()

	local function clear()
		file_timer:kill()
		if options.quit_after_inactivity > 0 then activity_timer:resume() end
		is_preview_visible = false
		mp.command_native_async({"overlay-remove", options.overlay_id}, function() end)
		if border_overlay then border_overlay:remove() end
	end

	local last_seek_time = -1
	local function generate_preview(time)
		if disabled then return end
		time = tonumber(time)
		if time == nil then return end

		is_preview_visible = true
		if real_w and real_h then draw(real_w, real_h) end

		if math.abs(time - last_seek_time) < 0.2 then return end
		last_seek_time = time
		
		if not spawned then spawn(time) else run_seek(time) end
		if not file_timer:is_enabled() then file_timer:resume() end
	end

	mp.observe_property("video-out-params", "native", function()
		local old_w, old_h = effective_w, effective_h
		if calc_dimensions() then
			if spawned and (old_w ~= effective_w or old_h ~= effective_h) then
				quit()
				spawn(last_seek_time >= 0 and last_seek_time or mp.get_property_number("time-pos", 0))
			end
		end
	end)

	local function file_load()
		clear()
		spawned = false
		real_w, real_h = nil, nil
		last_seek_time = -1
		if ipc_file then ipc_file:close(); ipc_file = nil end
		setup_preview_dir()
		calc_dimensions()
	end

	local function shutdown()
		quit()
		if ipc_file then ipc_file:close() end
		
		-- Cleanup preview files
		remove_preview_files()
		
		-- Attempt to remove the temp directory itself
		if preview_dir ~= "" then
			os.remove(preview_dir) 
		end
		
		if os_name ~= "windows" then os.remove(socket_path) end
	end

	mp.register_event("file-loaded", file_load)
	mp.register_event("shutdown", shutdown)

	-- HOVER DETECTION WITH 30FPS POLLING (Anti-Freeze)

	local function show_preview()
		if target_hover_time >= 0 then
			generate_preview(target_hover_time)
		end
	end

	-- This timer caps requests to 30/sec
	local update_timer = mp.add_periodic_timer(1/30, function()
		if showing then show_preview() end
	end)
	update_timer:kill()

	local function on_hover_time_change(name, value)
		-- Try to convert the property directly to a number
		local time_in_seconds = tonumber(value)
		
		-- If it's NOT a number (meaning it's "none", nil, or an empty string), hide it immediately
		if not time_in_seconds then
			showing = false
			update_timer:kill()
			clear()
			return
		end
		
		-- Otherwise, it's a valid time, so proceed with showing the preview
		target_hover_time = time_in_seconds

		-- Fetch mouse and OSD data just to know where to draw the preview horizontally
		local mouse = mp.get_property_native("mouse-pos")
		local osd = mp.get_property_native("osd-dimensions")
		
		if mouse and osd then
			local bw = options.use_border and options.border_width or 0
			
			preview_x = mouse.x - (effective_w / 2)
			if preview_x < bw then preview_x = bw end
			if preview_x + effective_w + bw > osd.w then preview_x = osd.w - effective_w - bw end
			
			-- Detect if the mouse is in the top half or bottom half and save globally
			is_topbar = mouse.y < (osd.h / 2)

			-- Dynamically parse script-opts to find the active osc-layout (Defaults to bottombar)
			local osc_layout = "bottombar" 
			local script_opts = mp.get_property("script-opts") or ""
			local match_layout = script_opts:match("osc%-layout=([^,]+)")
			if match_layout then osc_layout = match_layout:lower() end

			-- Check if the layout is one of the standard thick bars
			local is_standard_layout = (osc_layout == "topbar" or osc_layout == "bottombar")
			
			-- Apply logic per your instructions
			local apply_fixed = is_standard_layout and use_fixed_preview_height
			local offset = apply_fixed and fixed_preview_y_offset or dynamic_preview_y_offset

			if apply_fixed then
				if is_topbar then
					preview_y = offset
				else
					preview_y = osd.h - effective_h - offset
				end
			else
				if is_topbar then
					preview_y = mouse.y + offset + bw
				else
					preview_y = mouse.y - effective_h - offset - bw
				end
			end

			-- Safety boundaries to prevent the preview and chapters from getting cut off at the edges
			local chapter_offset = options.show_chapter and (options.chapter_font_size + 8) or 0
			
			if is_topbar then
				-- If chapter is ABOVE image, check top boundary
				if preview_y - chapter_offset - bw < bw then
					preview_y = chapter_offset + (bw * 2)
				end
				-- Check bottom boundary just in case
				if preview_y + effective_h + bw > osd.h then
					preview_y = osd.h - effective_h - bw
				end
			else
				-- If chapter is BELOW image, check bottom boundary
				if preview_y < bw then preview_y = bw end
				if preview_y + effective_h + chapter_offset + bw > osd.h then 
					preview_y = osd.h - effective_h - chapter_offset - bw 
				end
			end
		end

		-- Trigger visual updates
		if not showing then
			showing = true
			show_preview() -- Call instantly once
			update_timer:resume() -- Let the timer handle subsequent updates
		end
	end

	-- Observe the property as a string (this handles both float numbers and the word "none")
	mp.observe_property("user-data/osc/hovered-time", "string", on_hover_time_change)
	
end
