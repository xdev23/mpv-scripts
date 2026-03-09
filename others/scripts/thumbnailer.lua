-- Set to true to enable the script, false to disable it
local use_script = true

if not use_script then return end

local options = {
	max_height = 350,
	max_width = 350,
	overlay_id = 42,

	-- Border Options
	use_border = true,
	border_width = 2,
	border_color = "FFFFFF",
	border_alpha = 255,

	-- Chapter Options
	show_chapter = true,
	use_background_for_thumbnail_chapter = true,
	chapter_bg_color = "FFFFFF",
	chapter_text_color = "000000",
	chapter_font_size = 18
}

local mp = require 'mp'
local utils = require 'mp.utils'

-- Positioning Configuration
local use_fixed_preview_height = true
local fixed_preview_y_offset = 90
local dynamic_preview_y_offset = 60

local os_name = mp.get_property("platform") or "linux"
if os_name:match("windows") or os_name:match("mingw") then os_name = "windows" end

-- State variables
local effective_w, effective_h = options.max_width, options.max_height
local is_preview_visible = false
local preview_x = 20
local preview_y = 20
local target_hover_time = -1
local is_topbar = false

-- Establish the temp file path for the C plugin to write to
local temp_dir = (os_name == "windows") and os.getenv("TEMP") or "/tmp"
local preview_filepath = utils.join_path(temp_dir, "mpv_cplugin_preview.bgra")

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
		if time >= chap.time then current_chap = chap.title else break end
	end
	
	if not current_chap and time < chapters[1].time then current_chap = chapters[1].title end
	return current_chap
end

-- Helper to estimate text width and truncate
local function truncate_text(text, max_w, font_size)
	if not text or text == "" then return "" end
	local char_w = font_size * 0.55
	local max_chars = math.floor(max_w / char_w)
	if #text > max_chars then return text:sub(1, math.max(1, max_chars - 3)) .. "..." end
	return text
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
	
	-- Tell the C Plugin what resolution we want
	mp.set_property_number("user-data/c_plugin/width", effective_w)
	mp.set_property_number("user-data/c_plugin/height", effective_h)
	return true
end

local function draw()
	if not is_preview_visible or target_hover_time < 0 then return end
	
	-- Draw Image Overlay (Reading the .bgra file the C plugin just created)
	mp.command_native_async({
		"overlay-add", options.overlay_id, preview_x, preview_y, 
		preview_filepath, 0, "bgra", effective_w, effective_h, (4 * effective_w)
	}, function() end)

	-- Draw Border and Chapter overlays
	if border_overlay then
		local osd = mp.get_property_native("osd-dimensions")
		if osd then
			border_overlay.res_x = osd.w
			border_overlay.res_y = osd.h
			
			local ass_data = ""
			local bw = options.use_border and options.border_width or 0
			
			if options.use_border then
				local b_color, b_alpha = get_ass_color_and_alpha(options.border_color, options.border_alpha)
				ass_data = ass_rect(preview_x - bw, preview_y - bw, effective_w + (bw * 2), bw, b_color, b_alpha) .. "\n" ..
						   ass_rect(preview_x - bw, preview_y + effective_h, effective_w + (bw * 2), bw, b_color, b_alpha) .. "\n" ..
						   ass_rect(preview_x - bw, preview_y, bw, effective_h, b_color, b_alpha) .. "\n" ..
						   ass_rect(preview_x + effective_w, preview_y, bw, effective_h, b_color, b_alpha)
			end

			if options.show_chapter then
				local chap_title = get_chapter_at_time(target_hover_time)
				if chap_title and chap_title ~= "" then
					local fs = options.chapter_font_size
					local chap_text = truncate_text(chap_title, effective_w - 10, fs)
					local chap_h = fs + 8
					local chap_y = is_topbar and (preview_y - chap_h - bw) or (preview_y + effective_h + bw)
					
					if options.use_background_for_thumbnail_chapter then
						local bg_c, bg_a = get_ass_color_and_alpha(options.chapter_bg_color, 255)
						if ass_data ~= "" then ass_data = ass_data .. "\n" end
						ass_data = ass_data .. ass_rect(preview_x - bw, chap_y, effective_w + (bw * 2), chap_h, bg_c, bg_a)
					end
					
					local txt_c, txt_a = get_ass_color_and_alpha(options.chapter_text_color, 255)
					local text_style = options.use_background_for_thumbnail_chapter and "\\bord0\\shad0" or "\\bord1\\shad1\\3c&HFFFFFF&"
					local text_line = string.format("{\\an5\\pos(%d,%d)\\1c%s\\1a%s\\fs%d%s\\q2}%s", 
						preview_x + (effective_w / 2), chap_y + (chap_h / 2), txt_c, txt_a, fs, text_style, chap_text)
						
					if ass_data ~= "" then ass_data = ass_data .. "\n" end
					ass_data = ass_data .. text_line
				end
			end

			if ass_data ~= "" then
				border_overlay.data = ass_data
				border_overlay:update()
			else
				border_overlay:remove()
			end
		end
	end
end

local function clear()
	is_preview_visible = false
	target_hover_time = -1
	mp.command_native_async({"overlay-remove", options.overlay_id}, function() end)
	if border_overlay then border_overlay:remove() end
end

-- OBSERVE THE C PLUGIN
-- When the C plugin finishes writing the file, it will update this property.
mp.observe_property("user-data/c_plugin/ready_time", "number", function(name, ready_time)
	if ready_time and target_hover_time >= 0 and math.abs(ready_time - target_hover_time) < 0.1 then
		is_preview_visible = true
		draw()
	end
end)

local function on_hover_time_change(name, value)
	local time_in_seconds = tonumber(value)
	
	if not time_in_seconds then
		clear()
		return
	end
	
	target_hover_time = time_in_seconds

	-- Position math
	local mouse = mp.get_property_native("mouse-pos")
	local osd = mp.get_property_native("osd-dimensions")
	
	if mouse and osd then
		local bw = options.use_border and options.border_width or 0
		preview_x = mouse.x - (effective_w / 2)
		if preview_x < bw then preview_x = bw end
		if preview_x + effective_w + bw > osd.w then preview_x = osd.w - effective_w - bw end
		
		is_topbar = mouse.y < (osd.h / 2)
		local osc_layout = (mp.get_property("script-opts") or ""):match("osc%-layout=([^,]+)") or "bottombar"
		local apply_fixed = (osc_layout == "topbar" or osc_layout == "bottombar") and use_fixed_preview_height
		local offset = apply_fixed and fixed_preview_y_offset or dynamic_preview_y_offset

		if apply_fixed then
			preview_y = is_topbar and offset or (osd.h - effective_h - offset)
		else
			preview_y = is_topbar and (mouse.y + offset + bw) or (mouse.y - effective_h - offset - bw)
		end

		local chapter_offset = options.show_chapter and (options.chapter_font_size + 8) or 0
		if is_topbar then
			if preview_y - chapter_offset - bw < bw then preview_y = chapter_offset + (bw * 2) end
			if preview_y + effective_h + bw > osd.h then preview_y = osd.h - effective_h - bw end
		else
			if preview_y < bw then preview_y = bw end
			if preview_y + effective_h + chapter_offset + bw > osd.h then preview_y = osd.h - effective_h - chapter_offset - bw end
		end
	end

	-- TELL THE C PLUGIN TO DO THE WORK
	mp.set_property_native("user-data/c_plugin/out_path", preview_filepath)
	mp.set_property_number("user-data/c_plugin/request_time", target_hover_time)
end

mp.observe_property("user-data/osc/hovered-time", "string", on_hover_time_change)

mp.register_event("file-loaded", function()
	clear()
	calc_dimensions()
end)

mp.observe_property("video-out-params", "native", function()
	calc_dimensions()
end)