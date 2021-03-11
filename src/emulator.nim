import cpu, renderer, gpu, cdrom, gte

var sideload = false
var sideloadfile = "./exes/PSXNICCC.exe"

var gte_tests = false
if gte_tests:
    gte_ops_test()

rungame = true
# Games that atleast show something:
# Puzzle Bobble 2 - stuck on "Now loading"
# Raiden Project - gets to menu waiting for select
gamefile_name = "games/rp/Raiden Project.bin"
gamefile_region = 'A'
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
