-- Set to true to enable the script, false to disable it
local use_script = true

if use_script then
    local utils = require 'mp.utils'

    local function restart_mpv()
        -- Get the path of the currently playing file
        local current_file = mp.get_property('path')

        -- Quit the current mpv instance
        mp.command_native({"quit"})

        local args = {}
        -- Pass the last opened file to the new mpv instance
        if current_file then
            args.args = {"mpv", current_file}
        else
            args.args = {"mpv"}
        end

        utils.subprocess_detached(args)
    end

    mp.add_key_binding("F7", "restart-mpv", restart_mpv)
end