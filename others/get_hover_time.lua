-- Set to true to enable the script, false to disable it
local use_script = false

if use_script then

	local mp = require 'mp'
	local opt = require 'mp.options'

	-- Read the actual OSC settings from your mpv config automatically
	local osc_opts = {
		scalewindowed = 1,
		scalefullscreen = 1,
		vidscale = "auto",
		barmargin = 0,
	}
	opt.read_options(osc_opts, "osc")

	-- This function runs automatically every time the mouse moves
	local function on_mouse_move(name, mouse)
		-- If mouse data is missing, stop
		if not mouse then return end

		-- Pull live properties
		local osd = mp.get_property_native("osd-dimensions")
		local duration = mp.get_property_number("duration")
		local fullscreen = mp.get_property_native("fullscreen")

		if not (osd and duration and duration > 0) then return end

		-- 1. Get the current scale
		local scale = fullscreen and osc_opts.scalefullscreen or osc_opts.scalewindowed

		-- 2. Figure out if we are scaling with the video
		local scale_with_video
		if osc_opts.vidscale == "auto" then
			scale_with_video = mp.get_property_native("osd-scale-by-window")
		else
			scale_with_video = (osc_opts.vidscale == "yes")
		end

		-- 3. Virtual canvas math WITH your custom scaling applied
		local baseResY = 720
		local unscaled_y = scale_with_video and baseResY or osd.h
		local playresy = unscaled_y / scale
		local display_aspect = osd.w / osd.h
		local playresx = playresy * display_aspect

		-- Convert real mouse X and Y to scaled virtual coordinates
		local virt_mouse_x = mouse.x * (playresx / osd.w)
		local virt_mouse_y = mouse.y * (playresy / osd.h)

		-- 4. Calculate UI widths (X-axis)
		local padX = 9
		local buttonW = 27
		local tsW = 90
		local tcW = 110
		local padwc_l = 0
		local padwc_r = 0 
		
		local osc_geo_x = -2
		local osc_geo_w = playresx + 4

		local play_pause_x = osc_geo_x + padX + padwc_l
		local chapter_prev_x = play_pause_x + buttonW + padX
		local chapter_next_x = chapter_prev_x + buttonW + padX
		local tc_left_x = chapter_next_x + buttonW + padX + tcW
		local sb_l = tc_left_x + padX

		local fullscreen_x = osc_geo_x + osc_geo_w - buttonW - padX - padwc_r
		local volume_x = fullscreen_x - buttonW - padX
		local sub_track_x = volume_x - tsW - padX
		local audio_track_x = sub_track_x - tsW - padX
		local tc_right_x = audio_track_x - padX - tcW - 10
		local sb_r = tc_right_x - padX

		-- 5. Calculate UI heights (Y-axis) based on osc.lua bottombar math
		local sb_y_top = playresy - 30 - osc_opts.barmargin
		local sb_y_bottom = playresy - osc_opts.barmargin

		-- 6. STRICT HITBOX CHECK: Is the mouse physically inside the seekbar?
		if virt_mouse_x >= sb_l and virt_mouse_x <= sb_r and virt_mouse_y >= sb_y_top and virt_mouse_y <= sb_y_bottom then
			
			-- Calculate slider width using the exact scaled endpoints
			local slider_start = sb_l + 2
			local slider_end = sb_r - 2
			local slider_width = slider_end - slider_start

			if slider_width <= 0 then return end

			-- Calculate percentage
			local percent = (virt_mouse_x - slider_start) / slider_width
			if percent < 0 then percent = 0 end
			if percent > 1 then percent = 1 end

			-- Calculate time and print to OSD
			local hover_time = percent * duration
			
			-- We set the OSD message to last for 1 second. 
			-- As long as you keep moving the mouse on the bar, this 1-second timer keeps refreshing.
			-- When you move the mouse away, it naturally fades out.
			mp.osd_message(mp.format_time(hover_time), 1)
		end
	end

	-- Hook into the mouse-pos property so it triggers on movement
	mp.observe_property("mouse-pos", "native", on_mouse_move)
	
end