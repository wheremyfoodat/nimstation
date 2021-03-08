import times
import cpu, renderer, gpu, cdrom

var sideload = false
var sideloadfile = "./exes/VBLANK.exe"

rungame = true
# Games that atleast show something:
# Puzzle Bobble 2 - stuck on now loading
# Raiden Project - gets to menu waiting for select
gamefile_name = "games/rr/Ridge Racer (Track 01).bin"
gamefile_region = 'A'
if rungame:
    read_game()

if sideload:
    set_sideload(sideloadfile)

var fastboot = false
if fastboot:
    set_fastboot()

var frame_time = 0'f32

#var interrupt_state = InterruptState()

while true:
    let time = cpuTime()
    tick_flags()
    tick_gpu()
    run_next_instruction()
    tick_gpu()

    frame_time += cpuTime() - time
    if frame_time >= 0.016:
        parse_events()
        frame_time = 0
