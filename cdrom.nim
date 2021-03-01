import strutils
import interrupt

type
    Fifo = ref object
        buffer: array[16, uint8]
        write_idx: uint8
        read_idx: uint8

proc fifo_is_empty(fifo: Fifo): bool =
    return fifo.write_idx == fifo.read_idx

proc fifo_is_full(fifo: Fifo): bool =
    return fifo.write_idx == (fifo.read_idx xor 0x10'u8)

proc fifo_clear(fifo: Fifo) =
    fifo.write_idx = 0'u8
    fifo.read_idx = 0'u8

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

var responses = Fifo()
var parameters = Fifo()
var index = 0'u8
var irq_flags = 0'u8
var irq_mask = 0'u8
var seek_target = 0'u32

proc irq(): bool =
    return (irq_flags and irq_mask) != 0

proc trigger_irq(irqval: uint8, delay: uint16) =
    irq_flags = irqval
    if irq():
        pend_irq(delay, Interrupt.CdRom)


proc cdrom_irq_ack(value: uint8) =
    irq_flags = irq_flags and (not value)

proc cdrom_set_interrupt_mask(value: uint8) =
    irq_mask = value and 0x1F'u8

proc cmd_get_stat() =
    let status = 0x10'u8
    fifo_push(responses, status)
    trigger_irq(3'u8, 25000)

proc get_bios_date() =
    fifo_push(responses, 0x98'u8)
    fifo_push(responses, 0x06'u8)
    fifo_push(responses, 0x10'u8)
    fifo_push(responses, 0xC3'u8)
    trigger_irq(3'u8, 25000)

proc cmd_test() =
    let sub_command = fifo_pop(parameters)
    case sub_command:
        of 0x20: get_bios_date()
        else: quit("CDROM Unhandled test command " & sub_command.toHex(), QuitSuccess)

proc cmd_init() =
    let status = 0x10'u8
    fifo_push(responses, status)
    trigger_irq(3'u8, 25000)
    trigger_irq(2'u8, 50000)

proc cmd_get_id() =
    let status = 0x00'u8
    fifo_push(responses, status)
    fifo_push(responses, status)
    fifo_push(responses, 0x00'u8)
    fifo_push(responses, 0x20'u8)
    fifo_push(responses, 0x00'u8)
    fifo_push(responses, uint8('S'))
    fifo_push(responses, uint8('C'))
    fifo_push(responses, uint8('E'))
    fifo_push(responses, uint8('E'))
    trigger_irq(3'u8, 25000)
    trigger_irq(2'u8, 50000)

proc cmd_read_toc() =
    let status = 0x10'u8
    fifo_push(responses, status)
    fifo_push(responses, status)
    trigger_irq(3'u8, 25000)
    trigger_irq(2'u8, 50000)

proc run_command(value: uint8) =
    case value:
        of 0x01: cmd_get_stat()
        of 0x0A: cmd_init()
        of 0x19: cmd_test()
        of 0x1A: cmd_get_id()
        #of 0x1E: cmd_read_toc()
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

    if fifo_is_full(parameters):
        r = r or (1'u8 shl 4)

    if fifo_is_empty(responses):
        r = r or (1'u8 shl 5)

    return r

proc cdrom_store8*(offset: uint32, value: uint8) =
    case offset:
        of 0: index = value and 3
        of 1:
            case index:
                of 0: run_command(value)
                else: quit("unhandled cdrom offset 1", QuitSuccess)
        of 2:
            case index:
                of 0: set_parameter(value)
                of 1: cdrom_set_interrupt_mask(value)
                else: quit("unhandled cdrom offset 2", QuitSuccess)
        of 3:
            case index:
                of 1:
                    cdrom_irq_ack(value and 0x1F)
                    if (value and 0x40) != 0:
                        fifo_clear(parameters)
                else: quit("unhandled cdrom offset 3", QuitSuccess)
        else: quit("unhandled cdrom offset", QuitSuccess)

proc cdrom_load8*(offset: uint32): uint8 =
    case offset:
        of 0:
            #echo "CDROM: status read"
            return status()
        of 1:
            if fifo_is_empty(responses):
                quit("CDROM: Response FIFO underflow", QuitSuccess)
            else:
                let response = fifo_pop(responses)
                return response
        of 3:
            case index:
                of 1: return (irq_flags or 0xE0'u8)
                else:
                    echo "CDROM: unhandled load 8 ", offset.toHex()
                    return 0x00'u8
        else:
            echo "CDROM: unhandled load 8 ", offset.toHex()
            return 0x00'u8
