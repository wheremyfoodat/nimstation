import times
import cpu, renderer, gpu, cdrom

var sideload = false
var sideloadfile = "./exes/psxtest_cpu.exe"

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

    #frame_time += cpuTime() - time
    #if frame_time >= 0.016:
        #render_frame()
    #    frame_time = 0
