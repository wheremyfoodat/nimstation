import strutils, streams
import interrupt

type
    Fifo = ref object
        buffer: array[16, uint8]
        write_idx: uint8
        read_idx: uint8

    Datafifo = ref object
        buffer: array[2352, uint8]
        read_idx: uint16
        write_idx: uint16

var filebuffer = Datafifo()

proc fifo_is_empty(fifo: Fifo): bool =
    return fifo.write_idx == fifo.read_idx

proc fifo_is_full(fifo: Fifo): bool =
    return fifo.write_idx == (fifo.read_idx xor 0x10'u8)

proc fifo_clear(fifo: Fifo) =
    fifo.write_idx = 0'u8
    fifo.read_idx = 0'u8
    for i in 0 ..< 16:
        fifo.buffer[i] = 0'u8

proc fifo_len(fifo: Fifo): uint8 =
    return (fifo.write_idx - fifo.read_idx) and 0x1F'u8

proc fifo_push(fifo: Fifo, value: uint8) =
    let idx = fifo.write_idx and 0xF'u8
    fifo.buffer[idx] = value
    fifo.write_idx = (fifo.write_idx + 1) and 0x1F'u8

proc fifo_pop(fifo: Fifo): uint8 =
    let idx = fifo.read_idx and 0xF'u8
    fifo.read_idx = (fifo.read_idx + 1) and 0x1F
    return fifo.buffer[idx]

var reading: bool

var responses = Fifo()
var parameters = Fifo()
var index = 0'u8
var irq_flags = 0'u8
var irq_mask = 0'u8
var seek_target_m: uint8
var seek_target_s: uint8
var seek_target_f: uint8
var seek_target_pending: bool
var position_m: uint8
var position_s: uint8
var position_f: uint8
var position: uint32
var mode: uint8
var double_speed: bool
var xa_adpcm_to_spu: bool
var read_whole_sector: bool
var filter_enabled: bool

var pending_flag: uint8
var pending_flag_delay: uint32
var pending_flag2: uint8
var pending_flag_delay2: uint32

var next_int1: uint32
var first_read: bool
var last_int1: uint32
var frames_passed: uint8

var rx_len: uint16
var rx_active: bool

var first_pass: bool
var cdrom_debug*: bool
var dump_regs*: bool
var get_stat_count: uint8

proc bcd_to_int(val: uint8): uint8 =
    var result = 0'u8
    result = result * 100 + (val shr 4) * 10 + (val and 15)
    return result


proc irq(): bool =
    #echo "flags: ", int64(irq_flags).toBin(8), " mask: ", int64(irq_mask).toBin(8)
    return (irq_flags and irq_mask) != 0

proc trigger_irq1(irqval: uint8, delay: uint32) =
    irq_flags = irqval
    if irq():
        pend_irq(delay, Interrupt.CdRom)

proc trigger_irq2(irqval: uint8, delay: uint32) =
    let prev_flag = irq_flags
    irq_flags = irqval
    pending_flag = irqval
    pending_flag_delay = delay
    if irq():
        pend_irq(delay, Interrupt.CdRom)
    irq_flags = prev_flag

proc read_sector() =
    var gamefile = newFileStream("games/cc/Crossroad Crisis.bin", fmRead)

    echo "CDROM read sector at offset ", position.toHex()
    for i in (0 ..< position):
        discard gamefile.readChar()

    if read_whole_sector:
        for i in (0 ..< 12):
            discard gamefile.readChar()
        for i in (0 ..< 2340):
            filebuffer.buffer[filebuffer.write_idx] = uint8(gamefile.readChar())
            filebuffer.write_idx += 1
        rx_len = 2340'u16
    else:
        for i in (0 ..< 24):
            discard gamefile.readChar()
        for i in (0 ..< 2048):
            filebuffer.buffer[filebuffer.write_idx] = uint8(gamefile.readChar())
            filebuffer.write_idx += 1
        rx_len = 2048'u16

    #echo "CDROM first 20 bytes = ", filebuffer.buffer[0 ..< 20]
    position += 2352

    filebuffer.write_idx = 0
    filebuffer.read_idx = 0


proc cdrom_irq_ack(value: uint8) =
    #echo "cdrom irq ack value ", int64(value).toBin(8)
    irq_flags = irq_flags and (not value)

proc cdrom_set_interrupt_mask(value: uint8) =
    #echo "Setting CDROM irq mask to ", int64(value and 0x1F'u8).toBin(8)
    irq_mask = value and 0x1F'u8

proc do_seek() =
    position_m = seek_target_m
    position_s = seek_target_s
    position_f = seek_target_f
    #if double_speed:
    #    position = (uint32(position_s - 2) * 150) + uint32(position_f) * 2352
    #else:
    position = (((uint32(position_m)*60 + uint32(position_s - 2)) * 75) + uint32(position_f)) * 2352

    seek_target_pending = false

proc drive_status(): uint8 =
    var r = 0'u8
    r = r or (1 shl 1) # motor on
    if reading:
        r = r or (1 shl 5) # 1 if reading
    #return 0x10 #if no game
    return r

proc cmd_get_stat() =
    let status = drive_status()
    fifo_push(responses, status)
    trigger_irq1(3'u8, 50000'u32)
    get_stat_count += 1
    if get_stat_count == 4:
        discard
        #cdrom_debug = true

proc get_bios_date() =
    fifo_push(responses, 0x98'u8)
    fifo_push(responses, 0x06'u8)
    fifo_push(responses, 0x10'u8)
    fifo_push(responses, 0xC3'u8)
    trigger_irq1(3'u8, 50000'u32)

proc cmd_test() =
    let sub_command = fifo_pop(parameters)
    case sub_command:
        of 0x20: get_bios_date()
        else: quit("CDROM Unhandled test command " & sub_command.toHex(), QuitSuccess)

proc cmd_init() =
    var status = drive_status()
    fifo_push(responses, status)
    reading = false
    status = drive_status()
    fifo_push(responses, status)
    double_speed = false
    read_whole_sector = true
    filter_enabled = false
    xa_adpcm_to_spu = false
    position_m = 0
    seek_target_m = 0
    position_s = 0
    seek_target_s = 0
    position_f = 0
    seek_target_f = 0
    position = 0
    mode = 0
    trigger_irq1(3'u8, 80000'u32)
    trigger_irq2(2'u8, 130000'u32)
    if not first_pass:
        #cdrom_debug = true
        first_pass = true

proc cmd_get_id() =
    let status = drive_status()
    fifo_push(responses, status)
    fifo_push(responses, status) # drive status?
    fifo_push(responses, 0x00'u8) # licensed etc
    fifo_push(responses, 0x20'u8) # disc type
    fifo_push(responses, 0x00'u8)
    fifo_push(responses, uint8('S'))
    fifo_push(responses, uint8('C'))
    fifo_push(responses, uint8('E'))
    fifo_push(responses, uint8('A'))
    trigger_irq1(3'u8, 50000'u32)
    trigger_irq2(2'u8, 70000'u32)



proc cmd_read_toc() =
    reading = true
    let status = drive_status()
    fifo_push(responses, status)
    fifo_push(responses, status)
    trigger_irq1(3'u8, 50000'u32)
    trigger_irq2(2'u8, 120000'u32)
    reading = false

proc cmd_set_loc() =
    let m = fifo_pop(parameters)
    let s = fifo_pop(parameters)# - 2
    let f = fifo_pop(parameters)
    seek_target_m = bcd_to_int(m)
    seek_target_s = bcd_to_int(s)
    seek_target_f = bcd_to_int(f)

    echo "CDROM set loc to m ", seek_target_m, " s ", seek_target_s, " f ", seek_target_f

    #seek_target =
    seek_target_pending = true
    let status = drive_status()
    fifo_push(responses, status)
    trigger_irq1(3'u8, 50000'u32)

proc cmd_seek_l() =
    do_seek()
    let status = drive_status()
    fifo_push(responses, status)
    fifo_push(responses, status)
    trigger_irq1(3'u8, 50000'u32)
    trigger_irq2(2'u8, 90000'u32)

proc cmd_set_mode() =
    mode = fifo_pop(parameters)

    double_speed = ((mode shr 7) and 1) != 0
    xa_adpcm_to_spu = ((mode shr 6) and 1) != 0
    read_whole_sector = ((mode shr 5) and 1) != 0
    filter_enabled = ((mode shr 3) and 1) != 0
    let status = drive_status()
    fifo_push(responses, status)
    trigger_irq1(3'u8, 50000'u32)

proc cmd_read() =
    reading = true
    var status = drive_status()
    fifo_push(responses, status)
    trigger_irq1(3'u8, 50000'u32)
    read_sector()
    first_read = true
    if double_speed:
        next_int1 = 501000
    else:
        next_int1 = 275000

proc cmd_pause() =
    var status = drive_status()
    let prev_reading = reading
    reading = false
    fifo_push(responses, status)
    status = drive_status()
    fifo_push(responses, status)
    trigger_irq1(3'u8, 50000'u32)
    if prev_reading:
        if double_speed:
            trigger_irq2(2'u8, 1200000'u32)
        else:
            trigger_irq2(2'u8, 2300000'u32)
    else:
        trigger_irq2(2'u8, 58000'u32)

proc cmd_demute() =
    let status = drive_status()
    fifo_push(responses, status)
    trigger_irq1(3'u8, 50000'u32)

proc tick_flags*() =
    if reading:
        next_int1 -= 1
        if next_int1 == 0:
            if (irq_flags and 1) == 0:
                last_int1 = 0
                frames_passed = 0
                let status = drive_status()
                fifo_push(responses, status)
                if not first_read:
                    if not rx_active:
                        read_sector()
                else:
                    if not rx_active:
                        first_read = false

                if not rx_active:
                    trigger_irq2(1'u8, 1'u32)
                    if double_speed:
                        next_int1 = 45100
                    else:
                        next_int1 = 22500
                    #echo "CDROM triggered int1"

    if pending_flag_delay != 0:
        pending_flag_delay -= 1
        if pending_flag_delay == 0:
            irq_flags = pending_flag
            #echo "CDROM updated flags to ", int64(irq_flags).toBin(8)
            pending_flag = 0'u8

    if pending_flag_delay2 != 0:
        pending_flag_delay2 -= 1
        if pending_flag_delay2 == 0:
            irq_flags = pending_flag2
            #echo "CDROM updated flags to ", int64(irq_flags).toBin(8)
            pending_flag2 = 0'u8


proc run_command(value: uint8) =
    fifo_clear(responses)
    #echo "CDROM command: ", value.toHex()
    case value:
        of 0x01: cmd_get_stat()
        of 0x02: cmd_set_loc()
        of 0x06: cmd_read()
        of 0x09: cmd_pause()
        of 0x0A: cmd_init()
        of 0x0C: cmd_demute()
        of 0x0E: cmd_set_mode()
        of 0x15: cmd_seek_l()
        of 0x19: cmd_test()
        of 0x1A: cmd_get_id()
        of 0x1B: cmd_read()
        of 0x1E: cmd_read_toc()
        else: quit("CDROM Unhandled command " & value.toHex(), QuitSuccess)

proc set_parameter(value: uint8) =
    if fifo_is_full(parameters):
        quit("CDROM: Parameter FIFO overflow", QuitSuccess)
    fifo_push(parameters, value)

proc status(): uint8 =
    var r = index
    r = r or (0'u8 shl 2)
    if fifo_is_empty(parameters):
        r = r or (1'u8 shl 3)
    else:
        r = r or (0'u8 shl 3)

    if fifo_is_full(parameters):
        r = r or (0'u8 shl 4)
    else:
        r = r or (1'u8 shl 4)

    if fifo_is_empty(responses):
        r = r or (0'u8 shl 5)
    else:
        r = r or (1'u8 shl 5)

    if filebuffer.read_idx < rx_len:
        r = r or (1'u8 shl 6)
    else:
        r = r or (0'u8 shl 6)
    # busy bit?
    return r

proc read_byte(): uint8 =
    let b0 = filebuffer.buffer[filebuffer.read_idx]
    if rx_active:
        filebuffer.read_idx += 1
        if filebuffer.read_idx == rx_len:
            rx_active = false
    return b0

proc cdrom_dma_read_word*(): uint32 =
    let b0 = uint32(read_byte())
    let b1 = uint32(read_byte())
    let b2 = uint32(read_byte())
    let b3 = uint32(read_byte())
    return b0 or (b1 shl 8) or (b2 shl 16) or (b3 shl 24)

proc set_host_chip_control(value: uint8) =
    let prev_active = rx_active
    rx_active = (value and 0x80) != 0
    if rx_active:
        if not prev_active:
            filebuffer.read_idx = 0
    else:
        let i = filebuffer.read_idx
        let adjust = (i and 4) shl 1
        filebuffer.read_idx = (i and (not 7'u16)) + adjust

proc cdrom_store8*(offset: uint32, value: uint8) =
    #echo "CDROM store ", offset.toHex(), " ", index.toHex(), " ", value.toHex()
    case offset:
        of 0: index = value and 3
        of 1:
            case index:
                of 0: run_command(value)
                of 3: discard # mixer
                else: quit("unhandled cdrom offset 1", QuitSuccess)
        of 2:
            case index:
                of 0: set_parameter(value)
                of 1: cdrom_set_interrupt_mask(value)
                of 2, 3: discard # mixer
                else: quit("unhandled cdrom offset 2", QuitSuccess)
        of 3:
            case index:
                of 0: set_host_chip_control(value)
                of 1:
                    cdrom_irq_ack(value and 0x1F)
                    if (value and 0x40) != 0:
                        fifo_clear(parameters)
                of 2: discard #mixer cd left
                of 3: discard #mixer apply
                else: quit("unhandled cdrom offset 3", QuitSuccess)
        else: quit("unhandled cdrom offset", QuitSuccess)

proc cdrom_load8*(offset: uint32): uint8 =
    #echo "CDROM load ", offset.toHex(), " ", index.toHex()
    case offset:
        of 0:
            #echo "CDROM: status read ", int64(status()).toBin(8)
            #if cdrom_debug:
            #echo "CDROM status read: ", status().toHex()
            return status()
        of 1:
            if fifo_is_empty(responses):
                quit("CDROM: Response FIFO underflow", QuitSuccess)
            else:
                return fifo_pop(responses)
        of 3:
            case index:
                of 0: return (irq_mask or 0xE0'u8)
                of 1: return (irq_flags or 0xE0'u8)
                else:
                    quit("CDROM: unhandled load 8 " & offset.toHex(), QuitSuccess)
        else:
            quit("CDROM: unhandled load 8 " & offset.toHex(), QuitSuccess)
