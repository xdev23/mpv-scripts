# mpv-scripts
my mpv scripts

btw, to some extent i did use ai in these scripts,  

# restartmpv.lua

just press f7(default) key in mpv and mpv will restart with same video, useful when making conf or lua changes

# sync_v2.lua

this script is basically a watch together script

open multiple mpv with same or different files and you can sync play them, just create a leader and follower will auto sync, you can have multiple leader and every leader can have multiple followers,


open 2 or more mpv instance press `w` to create a leader, other mpv instance will see the leader just press `e` they will follow leader and sync play is started,
remember if file name is same then both video will play synced, if file name is not same then a offset is registered,

you can change the offset with keys mentioned and even reset/terminate it, remember there is **session recovery**, as long as one instance either leader or one of follower is active that session is recovered, this is because if other mpv crashes or quits accidently they can rejoin and start enjoying again, where they left

by default follower can't use controls and is muted by default, use `ctrl + f` for this so follower can get control access to unmute itself, if you want follower to change the seek position then just give follower controls access,

there are a lot of control options too, keys are role specific who have the role can use them

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

Ctrl+Shift+t: Reset/Terminate session, wiping all offset and session recovery, good for starting new session (Leader only)<br/>
Ctrl + Shift + w: Quit Leader and close all connected Followers (Leader only)

# ~~simple_thumb_v1b.lua~~ don't use this
# ~~simple_thumb_v1b.lua(with chapters support)~~ don't use this too

~~it can show thumbnail and chapters using hidden mpv instance just like thumbfast, but no osc.lua is required, just save this file to scripts folder thats it. enjoy.~~

`<img width="600" alt="Screenshot" src="https://github.com/user-attachments/assets/caff38b0-9f2b-4cf2-b8c1-9310c8da72f4" />`
