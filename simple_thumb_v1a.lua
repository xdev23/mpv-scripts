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
		border_alpha = 255       -- Opacity from 0 (transparent) to 255 (solid)
	}

	local mp = require 'mp'
	local opt = require 'mp.options'
	mp.utils = require "mp.utils"

	local use_fixed_preview_height = true
	local fixed_preview_y_offset = 70 

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

		-- Draw Border Overlay
		if options.use_border and border_overlay then
			local osd = mp.get_property_native("osd-dimensions")
			if osd then
				border_overlay.res_x = osd.w
				border_overlay.res_y = osd.h
				
				local b_color, b_alpha = get_ass_color_and_alpha(options.border_color, options.border_alpha)
				local bw = options.border_width
				
				-- Frame created from 4 connected rectangles so it doesn't overlap/block the image itself
				local top_bar   = ass_rect(preview_x - bw, preview_y - bw, w + (bw * 2), bw, b_color, b_alpha)
				local bot_bar   = ass_rect(preview_x - bw, preview_y + h, w + (bw * 2), bw, b_color, b_alpha)
				local left_bar  = ass_rect(preview_x - bw, preview_y, bw, h, b_color, b_alpha)
				local right_bar = ass_rect(preview_x + w, preview_y, bw, h, b_color, b_alpha)
				
				border_overlay.data = top_bar .. "\n" .. bot_bar .. "\n" .. left_bar .. "\n" .. right_bar
				border_overlay:update()
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

	-- HOVER detection uses 30fps otherwise it behaves wierdly

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
			
			if use_fixed_preview_height then
				preview_y = osd.h - effective_h - fixed_preview_y_offset
			else
				preview_y = mouse.y - effective_h - 15 - bw
			end
			if preview_y < bw then preview_y = bw end
		end

		-- Trigger visual updates
		if not showing then
			showing = true
			show_preview() -- Call instantly once
			update_timer:resume() -- Let the timer handle subsequent updates
		end
	end

	-- Observe the property as a string (this handles both float numbers and the word "none")
	mp.observe_property("user-data/osc/hover_mouse_time", "string", on_hover_time_change)
	

end
