import streams, strutils
import cdrom, interrupt, timers

# for pointer arithmetics in fastmem stuff
template `+`*[T](p: ptr T, off: int): ptr T =
  cast[ptr type(p[])](cast[ByteAddress](p) +% off * sizeof(p[]))

const REGION_MASK = [0xFFFFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32, 0x7FFFFFFF'u32, 0x1FFFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32]

type
    Step = enum
        Increment = 0,
        Decrement = 1

    Direction = enum
        ToRam = 0,
        FromRam = 1

    Sync = enum
        Manual = 0,
        Request = 1,
        LinkedList = 2

    Port = enum
        MdecIn = 0,
        MdecOut = 1,
        Gpu = 2,
        CdRom = 3,
        Spu = 4,
        Pio = 5,
        Otc = 6

    Channel = ref object
        enable: bool
        direction: Direction
        step: Step
        sync: Sync
        trigger: bool
        chop: bool
        chop_dma_sz: uint8
        chop_cpu_sz: uint8
        dummy: uint8

        base: uint32
        block_size: uint16
        block_count: uint16


var bios: array[0x80000, uint8]
var ram: array[0x200000, uint8]
var scratchpad: array[1024 , uint8]

var s = newFileStream("SCPH1001.BIN", fmRead)
var bios_pos = 0'u32
while not s.atEnd:
    bios[bios_pos] = uint8(s.readChar())
    bios_pos += 1

# software fastmem I hope
const PAGE_SIZE = 64 * 1024 # 64KB pages
var page_table_r: array[0x10000, ptr(uint8)]
var page_table_w: array[0x10000, ptr(uint8)]

for i in 0 ..< 0x10000:
    page_table_r[i] = nil
    page_table_w[i] = nil

for page_index in 0 ..< 128:
    let pointer = ram[(page_index * PAGE_SIZE) and 0x1FFFFF].addr
    page_table_r[page_index + 0x0000] = pointer
    page_table_r[page_index + 0x8000] = pointer
    page_table_r[page_index + 0xA000] = pointer
    page_table_w[page_index + 0x0000] = pointer
    page_table_w[page_index + 0x8000] = pointer
    page_table_w[page_index + 0xA000] = pointer

for page_index in 0 ..< 8:
    let pointer = bios[page_index * PAGE_SIZE].addr
    page_table_r[page_index + 0x1FC0] = pointer
    page_table_r[page_index + 0x9FC0] = pointer
    page_table_r[page_index + 0xBFC0] = pointer

var dma_control = 0x07654321'u32
var irq_en: bool
var channel_irq_en: uint8
var channel_irq_flags: uint8
var force_irq: bool
var irq_dummy: uint8
var channels = [Channel(), Channel(), Channel(), Channel(), Channel(), Channel(), Channel()]

proc dump_wram*() =
    echo "Dumping wram!"
    var s = newFileStream("wram.bin", fmWrite)
    for x in ram:
      s.write(x)
    s.close()
    echo "Done!"

# Import gpu finally, gpu wants access to dump_wram
import gpu

proc bus_sideload*(sideload_file: string): uint32 =
    echo "Sideloading ", sideload_file
    var s = newFileStream(sideload_file, fmRead)

    var magic = ""
    for i in (0 ..< 8):
        magic = magic & s.readChar()

    if magic != "PS-X EXE":
        quit("Invalid PSX EXE", QuitSuccess)

    for i in (0 ..< 8):
        discard s.readChar()

    var new_pc = 0'u32
    for i in (0 ..< 4):
        new_pc = new_pc or (cast[uint32](s.readChar()) shl (i * 8))

    for i in (0 ..< 4):
        discard s.readChar()

    var address = 0'u32
    for i in (0 ..< 4):
        address = address or (cast[uint32](s.readChar()) shl (i * 8))

    var index = address shr 29
    address = address and REGIONMASK[index]

    var size = 0'u32
    for i in (0 ..< 4):
        size = size or (cast[uint32](s.readChar()) shl (i * 8))

    for i in (0 ..< 2016):
        discard s.readChar()

    for i in (0 ..< size):
        ram[address + i] = cast[uint8](s.readChar())
        #address += 1

    echo "Magic: ", magic
    echo "New PC: 0x", new_pc.toHex()
    echo "Sideloading done!"

    return new_pc

proc channel_control(channel: Channel): uint32 =
    var r = 0'u32
    r = r or cast[uint32](ord(channel.direction))
    r = r or cast[uint32](ord(channel.step) shl 1)
    if channel.chop:
        r = r or (1 shl 8)
    r = r or cast[uint32](ord(channel.sync) shl 9)
    r = r or (cast[uint32](channel.chop_dma_sz) shl 16)
    r = r or (cast[uint32](channel.chop_cpu_sz) shl 20)
    if channel.enable:
        r = r or (1 shl 24)
    if channel.trigger:
        r = r or (1 shl 28)
    r = r or (cast[uint32](channel.dummy) shl 29)

proc set_channel_control(channel: Channel, value: uint32) =
    channel.direction = case ((value and 1) != 0):
        of true: Direction.FromRam
        of false: Direction.ToRam

    channel.step = case (((value shr 1) and 1) != 0):
        of true: Step.Decrement
        of false: Step.Increment

    channel.chop = ((value shr 8) and 1) != 0

    channel.sync = case ((value shr 9) and 3):
        of 0: Sync.Manual
        of 1: Sync.Request
        of 2: Sync.LinkedList
        else: quit("Unknown DMA sync mode " & ((value shr 9) and 3).toHex(), QuitSuccess)

    channel.chop_dma_sz = cast[uint8]((value shr 16) and 7)
    channel.chop_cpu_sz = cast[uint8]((value shr 20) and 7)

    channel.enable = ((value shr 24) and 1) != 0
    channel.trigger = ((value shr 28) and 1) != 0

    channel.dummy = cast[uint8]((value shr 29) and 3)

proc set_channel_base(channel: Channel, value: uint32) =
    channel.base = value and 0xFFFFFF

proc channel_block_control(channel: Channel): uint32 =
    return (cast[uint32](channel.block_count) shl 16) or cast[uint32](channel.block_size)

proc set_channel_block_control(channel: Channel, value: uint32) =
    channel.block_size = cast[uint16](value)
    channel.block_count = cast[uint16](value shr 16)

proc channel_active(channel: Channel): bool =
    let trigger = case channel.sync:
        of Sync.Manual: channel.trigger
        else: true
    return channel.enable and trigger

proc irq(): bool =
    let channel_irq = channel_irq_flags and channel_irq_en
    return force_irq or (irq_en and (channel_irq != 0))

proc interrupt(): uint32 =
    var r = 0'u32
    r = r or cast[uint32](irq_dummy)
    if force_irq:
        r = r or (1 shl 15)

    r = r or (cast[uint32](channel_irq_en) shl 16)
    if irq_en:
        r = r or (1 shl 23)

    r = r or (cast[uint32](channel_irq_flags) shl 24)
    if irq():
        r = r or (1 shl 31)

proc set_interrupt(value: uint32) =
    let prev_irq = irq()

    irq_dummy = uint8(value and 0x3F)
    force_irq = ((value shr 15) and 1) != 0
    channel_irq_en = uint8((value shr 16) and 0x7F)
    irq_en = ((value shr 24) and 1) != 0
    let ack = uint8((value shr 24) and 0x3F)
    channel_irq_flags = channel_irq_flags and (not ack)

    if (not prev_irq) and irq():
        pend_irq(1, Interrupt.Dma)

proc port_from_index(index: uint32): Port =
    case index:
        of 0: return Port.MdecIn
        of 1: return Port.MdecOut
        of 2: return Port.Gpu
        of 3: return Port.CdRom
        of 4: return Port.Spu
        of 5: return Port.Pio
        of 6: return Port.Otc
        else: quit("whats", QuitSuccess)

proc transfer_size(channel: Channel): uint32 =
    case channel.sync:
        of Sync.Manual: return cast[uint32](channel.block_size)
        of Sync.Request: return cast[uint32](channel.block_size * channel.block_count)
        else: quit("whats", QuitSuccess)

proc channel_done(channel: Channel, port: uint32) =
    channel.enable = false
    channel.trigger = false
    let prev_irq = irq()
    let it_en = channel_irq_en and (1'u8 shl uint8(port))
    channel_irq_flags = channel_irq_flags or it_en
    if (not prev_irq) and irq():
        pend_irq(1, Interrupt.Dma)

proc do_dma_block(channel: Channel, port_num: uint32) =

    let port = port_from_index(port_num)
    let increment = case channel.step:
        of Step.Increment: 4
        of Step.Decrement: -4

    var address = channel.base
    var remsz = transfer_size(channel)
    while remsz > 0'u32:
        let cur_addr = address and 0x1FFFFC'u32
        case channel.direction:
            of Direction.FromRam:
                # Let's use fastmem for DMA aswell
                let page = address shr 16 # divide by 64 to get the page number
                let offset = cast[int](address and 0xFFFF) # offset in page
                let pointer = page_table_r[page] # actual pointer
                let src_word = cast[ptr uint32](pointer + offset)[]
                case port:
                    of Port.Gpu: gp0(src_word)
                    else: quit("Unhandled DMA destination port" & ord(port).toHex(), QuitSuccess)
            of Direction.ToRam:
                let src_word = case port:
                    of Port.Otc:
                        case remsz:
                            of 1: 0xFFFFFF'u32
                            else: (address - 4) and 0x1FFFFFF'u32
                    of Port.Gpu: 0x00'u32
                    of Port.CdRom: cdrom_dma_read_word()
                    else: quit("Unhandled DMA source port " & ord(port).toHex(), QuitSuccess)
                let page = cur_addr shr 16 # divide by 64 to get the page number
                let offset = cast[int](cur_addr and 0xFFFF) # offset in page
                let pointer = page_table_w[page] # actual pointer
                cast[ptr uint32](pointer + offset)[] = src_word
        address = address + cast[uint32](increment)
        remsz -= 1
    channel_done(channel, port_num)

proc do_dma_linked_list(channel: Channel, port_num: uint32) =
    let port = port_from_index(port_num)
    var address = channel.base and 0x1FFFFC'u32
    if channel.direction == Direction.ToRam:
        quit("Invalid DMA direction for linked list mode", QuitSuccess)

    if port != Port.Gpu:
        quit("Attempted linked list DMA on port" & ord(port).toHex(), QuitSuccess)

    var run_dma = true
    while run_dma:
        let page = address shr 16 # divide by 64 to get the page number
        let offset = cast[int](address and 0xFFFF) # offset in page
        let pointer = page_table_r[page] # actual pointer
        let header = cast[ptr uint32](pointer + offset)[]
        var remsz = header shr 24
        while remsz > 0'u32:
            address = (address + 4) and 0x1FFFFC'u32
            let page = address shr 16 # divide by 64 to get the page number
            let offset = cast[int](address and 0xFFFF) # offset in page
            let pointer = page_table_r[page] # actual pointer
            let command = cast[ptr uint32](pointer + offset)[]
            gp0(command)
            remsz -= 1
        if (header and 0x800000'u32) != 0:
            run_dma = false
        address = header and 0x1FFFFC'u32
    channel_done(channel, port_num)

proc do_dma(port: uint32) =
    let channel = channels[port]
    case channel.sync:
        of Sync.LinkedList: do_dma_linked_list(channel, port)
        else: do_dma_block(channel, port)


proc dma_reg(offset: uint32) : uint32 =
    let major = (offset and 0x70) shr 4
    let minor = offset and 0xF
    case major:
        of 0 .. 6:
            let channel = channels[major]
            case minor:
                of 0: return channel.base
                of 4: return channel_block_control(channel)
                of 8: return channel_control(channel)
                else: quit("Unhandled DMA read at " & offset.toHex(), QuitSuccess)
        of 7:
            case minor:
                of 0: return dma_control
                of 4: return interrupt()
                else: quit("Unhandled DMA read at " & offset.toHex(), QuitSuccess)
        else: quit("Unhandled DMA read at " & offset.toHex(), QuitSuccess)

proc set_dma_reg(offset: uint32, value: uint32) =
    let major = (offset and 0x70) shr 4
    let minor = offset and 0xF
    var active_port = 0xFF'u32
    case major:
        of 0 .. 6:
            let channel = channels[major]
            case minor:
                of 0: set_channel_base(channel, value)
                of 4: set_channel_block_control(channel, value)
                of 8: set_channel_control(channel, value)
                else: quit("Unhandled DMA write at " & offset.toHex() & " " & value.toHex(), QuitSuccess)
            if channel_active(channel):
                active_port = major
        of 7:
            case minor:
                of 0: dma_control = value
                of 4: set_interrupt(value)
                else: quit("Unhandled DMA write at " & offset.toHex() & " " & value.toHex(), QuitSuccess)
        else: quit("Unhandled DMA write at " & offset.toHex() & " " & value.toHex(), QuitSuccess)

    if active_port != 0xFF'u8:
        do_dma(major)

# LOADS/STORES

proc load32_io(offset: uint32): uint32 =
    let index = offset shr 29
    let address = offset and REGIONMASK[index]
    if address in 0x1F801000'u32 ..< 0x1F801024'u32: # MEMCONTROL
        return 0x00'u32
    elif address == 0x1F801060'u32:  # RAM_SIZE
        return 0x00000B88'u32
    elif address in 0x1F801070'u32 ..< 0x1F801078'u32: # IRQ
        case address:
            of 0x1F801070: return get_irq_status()
            of 0x1F801074: return get_irq_mask()
            else:  quit("Invalid irq read32 address " & address.toHex(), QuitSuccess)
    elif address in 0x1F801080'u32 ..< 0x1F801100'u32: # DMA
         return dma_reg(address - 0x1F801080'u32)
    elif address in 0x1F801100'u32 ..< 0x1F801130'u32: # TIMERS
        return timers_load32(address - 0x1F801100'u32)
    elif address in 0x1F801810'u32 ..< 0x1F801818'u32: # GPU
        case address:
            of 0x1F801810: return gpu_read()
            of 0x1F801814: return gpu_status()
            else: return 0x00'u32
    else: quit("Unhandled load32io " & address.toHex(), QuitSuccess)

proc load16_io(offset: uint32): uint16 =
    let index = offset shr 29
    let address = offset and REGIONMASK[index]
    if address in 0x1F801040'u32 ..< 0x1F801060'u32: # PADMEM
        return 0xFFFF'u16
    elif address in 0x1F801070'u32 ..< 0x1F801078'u32: # IRQCONTROL
        case address:
            of 0x1F801070: return get_irq_status()
            of 0x1F801074: return get_irq_mask()
            else: quit("Invalid irq read16 address " & address.toHex(), QuitSuccess)
    elif address in 0x1F801100'u32 ..< 0x1F801130'u32: # TIMERS
        return 0x00'u16
    elif address in 0x1F801C00'u32 ..< 0x1F801E80'u32: # SPU
        return 0x00'u16
    else: quit("Unhandled load16io " & address.toHex(), QuitSuccess)

proc load8_io(offset: uint32): uint8 =
    let index = offset shr 29
    let address = offset and REGIONMASK[index]
    if address in 0x1F000000'u32 ..< 0x1F080000'u32: # Expansion
        return 0xFF'u8
    elif address in 0x1F801040'u32 ..< 0x1F801060'u32: # PADMEM
        return 0xFF'u8
    elif address in 0x1F801800'u32 ..< 0x1F801804'u32: # CDROM
        return cdrom_load8(address - 0x1F801800'u32)
    else: quit("Unhandled load8io " & address.toHex(), QuitSuccess)

proc load32*(address: uint32): uint32 =
    let page = address shr 16 # divide by 64 to get the page number
    let offset = cast[int](address and 0xFFFF) # offset in page
    let pointer = page_table_r[page] # actual pointer

    if pointer != nil:
        return cast[ptr uint32](pointer + offset)[]
    else:
        if (page == 0x1F80'u32) or (page == 0x9F80'u32) or (page == 0xBF80'u32):
            if (offset < 0x400'i32) and (page != 0xBF80'u32):
                let b0 = cast[uint32](scratchpad[offset + 0])
                let b1 = cast[uint32](scratchpad[offset + 1])
                let b2 = cast[uint32](scratchpad[offset + 2])
                let b3 = cast[uint32](scratchpad[offset + 3])
                return b0 or (b1 shl 8) or (b2 shl 16) or (b3 shl 24)
            else:
                return load32_io(address)
        else:
            quit("Unhandled load32 " & address.toHex(), QuitSuccess)

proc load16*(address: uint32): uint16 =
    let page = address shr 16 # divide by 64 to get the page number
    let offset = int(address and 0xFFFF) # offset in page
    let pointer = page_table_r[page] # actual pointer

    if pointer != nil:
        return cast[ptr uint16](pointer + offset)[]
    else:
        if (page == 0x1F80'u32) or (page == 0x9F80'u32) or (page == 0xBF80'u32):
            if (offset < 0x400'i32) and (page != 0xBF80'u32):
                let b0 = cast[uint16](scratchpad[offset + 0])
                let b1 = cast[uint16](scratchpad[offset + 1])
                return b0 or (b1 shl 8)
            else:
                return load16_io(address)
        else:
            quit("Unhandled load16 " & address.toHex(), QuitSuccess)

proc load8*(address: uint32): uint8 =
    let page = address shr 16 # divide by 64 to get the page number
    let offset = cast[int](address and 0xFFFF) # offset in page
    let pointer = page_table_r[page] # actual pointer

    if pointer != nil:
        return (pointer + offset)[]
    else:
        if (page == 0x1F80'u32) or (page == 0x9F80'u32) or (page == 0xBF80'u32) or (page == 0x1F00'u32):
            if (offset < 0x400'i32) and (page != 0xBF80'u32) and (page != 0x1F00'u32):
                return scratchpad[offset]
            else:
                return load8_io(address)
        else:
            quit("Unhandled load8 " & address.toHex(), QuitSuccess)

proc store32_io(offset: uint32, value: uint32) =
    let index = offset shr 29
    let address = offset and REGIONMASK[index]
    if address in 0x1F801000'u32 ..< 0x1F801024'u32:
        case address:
            of 0x1F801000:
                if value != 0x1F000000: quit("Bad expansion 1 base address 0x" & value.toHex(), QuitSuccess)
            of 0x1F801004:
                if value != 0x1F802000: quit("Bad expansion 2 base address 0x" & value.toHex(), QuitSuccess)
            else: discard #echo "Unhandled write to MEMCONTROL register"
    elif address in 0x1F801060'u32 ..< 0x1F801064'u32: discard
    elif address in 0x1F801070'u32 ..< 0x1F801078'u32: #IRQCONTROL
        case address:
            of 0x1F801070: irq_ack(cast[uint16](value))
            of 0x1F801074: irq_set_mask(cast[uint16](value))
            else: quit("Invalid irq store32 address " & address.toHex(), QuitSuccess)
    elif address in 0x1F801080'u32 ..< 0x1F801100'u32: # DMA
        set_dma_reg(address - 0x1F801080'u32, value)
    elif address in 0x1F801100'u32 ..< 0x1F801130'u32: # TIMERS
        timers_store16(address - 0x1F801100'u32, cast[uint16](value))
    elif address in 0x1F801810'u32 ..< 0x1F801818'u32: # GPU
        case address:
            of 0x1F801810: gp0(value)
            of 0x1F801814: gp1(value)
            else: quit("Unhandled GPU write " & address.toHex() & " " & value.toHex(), QuitSuccess)
    elif address in 0xFFFE0130'u32 ..< 0xFFFE0134'u32: discard # CACHECONTROL
    else: quit("Unhandled store32io " & address.toHex(), QuitSuccess)

proc store16_io(offset: uint32, value: uint16) =
    let index = offset shr 29
    let address = offset and REGIONMASK[index]
    if address in 0x1F801040'u32 ..< 0x1F801060'u32: discard # PADMEM
    elif address in 0x1F801070'u32 ..< 0x1F801078'u32: # IRQCONTROL
        case address:
            of 0x1F801070: irq_ack(value)
            of 0x1F801074: irq_set_mask(value)
            else: quit("Invalid irq store32 address " & address.toHex(), QuitSuccess)
    elif address in 0x1F801100'u32 ..< 0x1F801130'u32: # TIMERS
        timers_store16(address - 0x1F801100'u32, cast[uint16](value))
    elif address in 0x1F801C00'u32 ..< 0x1F801E80'u32: discard # SPU
    else: quit("Unhandled store16io " & address.toHex(), QuitSuccess)


proc store8_io(offset: uint32, value: uint8) =
    let index = offset shr 29
    let address = offset and REGIONMASK[index]
    if address == 0x1F801040'u32: discard # JOYDATA
    elif address in 0x1F801800'u32 ..< 0x1F801804'u32: # CDROM
        cdrom_store8(address - 0x1F801800'u32, value)
    elif address in 0x1F802000'u32 ..< 0x1F802042'u32: discard # Expansion 2
    elif address == 0x1F802080'u32: # PCSX register
        stdout.write char(value)
    else: quit("Unhandled store8io " & address.toHex(), QuitSuccess)

proc store32*(address: uint32, value: uint32) =
    let page = address shr 16 # divide by 64 to get the page number
    let offset = int(address and 0xFFFF) # offset in page
    let pointer = page_table_w[page] # actual pointer

    if pointer != nil:
        cast[ptr uint32](pointer + offset)[] = value
    else:
        if (page == 0x1F80) or (page == 0x9F80) or (page == 0xBF80) or (page == 0xFFFE):
            if (offset < 0x400) and (page != 0xBF80) and (page != 0xFFFE):
                scratchpad[offset + 0] = cast[uint8](value)
                scratchpad[offset + 1] = cast[uint8](value shr 8)
                scratchpad[offset + 2] = cast[uint8](value shr 16)
                scratchpad[offset + 3] = cast[uint8](value shr 24)
            else:
                store32_io(address, value)
        else:
            quit("Unhandled store32 " & address.toHex(), QuitSuccess)

proc store16*(address: uint32, value: uint16) =
    let page = address shr 16 # divide by 64 to get the page number
    let offset = int(address and 0xFFFF) # offset in page
    let pointer = page_table_w[page] # actual pointer

    if pointer != nil:
        cast[ptr uint16](pointer + offset)[] = value
    else:
        if (page == 0x1F80) or (page == 0x9F80) or (page == 0xBF80):
            if (offset < 0x400) and (page != 0xBF80):
                scratchpad[offset + 0] = cast[uint8](value)
                scratchpad[offset + 1] = cast[uint8](value shr 8)
            else:
                store16_io(address, value)
        else:
            quit("Unhandled store16 " & address.toHex(), QuitSuccess)

proc store8*(address: uint32, value: uint8) =
    let page = address shr 16 # divide by 64 to get the page number
    let offset = int(address and 0xFFFF) # offset in page
    let pointer = page_table_w[page] # actual pointer

    if pointer != nil:
        (pointer + offset)[] = value
    else:
        if (page == 0x1F80) or (page == 0x9F80) or (page == 0xBF80):
            if (offset < 0x400) and (page != 0xBF80):
                scratchpad[offset + 0] = cast[uint8](value)
            else:
                store8_io(address, value)
        else:
            quit("Unhandled store8 " & address.toHex(), QuitSuccess)
