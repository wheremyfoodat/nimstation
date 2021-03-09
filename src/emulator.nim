import cpu, renderer, gpu, cdrom

var sideload = false
var sideloadfile = "./exes/psxtest_cpu.exe"

rungame = true
# Games that atleast show something:
# Puzzle Bobble 2 - stuck on now loading
# Raiden Project - gets to menu waiting for select
gamefile_name = "games/pb2/Puzzle Bobble 2 (Japan) (Track 01).bin"
gamefile_region = 'I'
if rungame:
    read_game()

if sideload:
    set_sideload(sideloadfile)

var fastboot = false
if fastboot and rungame:
    set_fastboot()

while true:
    tick_flags()
    tick_gpu()
    run_next_instruction()
    tick_gpu()
    parse_events()
    #render_frame()
