# mpv-scripts
my mpv scripts

btw, to some extent i did use ai in these scripts,  

# restartmpv.lua

just press f7(default) key in mpv and mpv will restart with same video, useful when making conf or lua changes

# sync_v2.lua

this script is basically a watch together script

open multiple mpv with same or different files and you can sync play them, just create a leader and follower will auto sync, you can have multiple leader and every leader can have multiple followers,

keybindings are:

w (Short Press): Start Leader / Show Leader ID<br/>
w (Long Press): Stop Leader

e (Short Press): Start Follower / Join active Leader<br/>
e (Long Press): Stop Follower

Ctrl + f: Enable/Disable Follower controls (Leader only)<br/>
Ctrl + o: Open duplicated MPV window (Leader only)<br/>
Ctrl + e: Cycle to the next available Leader (Follower only)

Shift + e: Reset sync offset (Follower only)<br/>
Ctrl + r: Decrease sync offset by 0.1s (Follower only)<br/>
Ctrl + t: Increase sync offset by 0.1s (Follower only)

Ctrl + Shift + w: Quit Leader and close all connected Followers (Leader only)

# simple_thumb_v1b.lua(with chapters support)

it can show thumbnail and chapters using hidden mpv instance just like thumbfast, but no osc.lua is required, just save this file to scripts folder thats it. enjoy.

<img width="600" alt="Screenshot" src="https://github.com/user-attachments/assets/caff38b0-9f2b-4cf2-b8c1-9310c8da72f4" />
