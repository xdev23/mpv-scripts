-- Set to true to enable the script, false to disable it
local use_script = true

if use_script then

	local mp = require("mp")
	local ffi = require("ffi")

	-- 1. Load Windows API
	ffi.cdef[[
		typedef struct { long x; long y; } POINT;
		bool GetCursorPos(POINT *lpPoint);
		bool SetCursorPos(int X, int Y);
		int ShowCursor(bool bShow);
	]]
	local user32 = ffi.load("user32")

	-- Tracking Variables
	local locked = false
	local anchor_x, anchor_y = 0, 0
	local cumulative_dx = 0
	local cumulative_dy = 0
	local start_time = 0
	local start_vol = 0
	local original_deadzone = 3

	-- Sensitivities
	local seek_sensitivity = 0.2  -- Seconds to seek per pixel (Left/Right)
	local vol_sensitivity = 0.5   -- Volume percentage per pixel (Up/Down)

	-- 2. The 10ms Tracking Loop
	local function track_mouse()
		if not locked then return end

		local pt = ffi.new("POINT")
		user32.GetCursorPos(pt)

		-- Calculate the movement (dx, dy)
		local dx = pt.x - anchor_x
		local dy = pt.y - anchor_y

		-- If the mouse hasn't moved, do nothing
		if dx == 0 and dy == 0 then return end

		-- Add the tiny movements to our running totals
		cumulative_dx = cumulative_dx + dx
		cumulative_dy = cumulative_dy + dy

		-- Calculate the new Absolute Time and Volume
		local target_time = math.max(0, start_time + (cumulative_dx * seek_sensitivity))
		local target_vol = math.max(0, math.min(100, start_vol - (cumulative_dy * vol_sensitivity)))

		-- Apply the changes to mpv
		mp.commandv("seek", target_time, "absolute+exact")
		mp.set_property_number("volume", target_vol)
		
		-- Show OSD feedback
		mp.osd_message(string.format("Time: %.1f sec\nVolume: %d%%", target_time, target_vol), 1)

		-- Instantly snap the cursor back to the anchor point
		user32.SetCursorPos(anchor_x, anchor_y)
	end

	-- Run the tracking function every 10 milliseconds
	local track_timer = mp.add_periodic_timer(0.01, track_mouse)
	track_timer:kill() -- Pause it until we click

	-- 3. Handle the Left Mouse Button Clicks
	local function on_click(table)
		if table.event == "down" then
			local pt = ffi.new("POINT")
			user32.GetCursorPos(pt)
			
			-- Save anchor coordinates and current video states
			anchor_x, anchor_y = pt.x, pt.y
			cumulative_dx = 0
			cumulative_dy = 0
			start_time = mp.get_property_number("time-pos") or 0
			start_vol = mp.get_property_number("volume") or 100
			locked = true
			
			-- Apply the deadzone trick to prevent mpv window dragging
			original_deadzone = mp.get_property_number("input-dragging-deadzone") or 3
			local dim = mp.get_property_native("osd-dimensions")
			local w = dim and dim.w or 9999
			local h = dim and dim.h or 9999
			mp.set_property_number("input-dragging-deadzone", math.max(w, h))

			-- Hide the Windows cursor and start tracking
			user32.ShowCursor(false)
			track_timer:resume()
			
		elseif table.event == "up" then
			locked = false
			track_timer:kill()
			
			-- Restore the original deadzone
			mp.set_property_number("input-dragging-deadzone", original_deadzone)

			-- Show the Windows cursor again
			user32.ShowCursor(true)
			mp.osd_message("Finished", 1)
		end
	end

	-- 4. Bind to Left Click
	mp.add_forced_key_binding("MBTN_LEFT", "lock_and_adjust", on_click, {complex = true})

end