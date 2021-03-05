import strutils, opengl
import renderer, counters, interrupt

const VRAM_SIZE_PIXELS = 1024 * 512
type
    TextureDepth = enum
        T4Bit = 0,
        T8Bit = 1,
        T15Bit = 2

    Field = enum
        Bottom = 0,
        Top = 1

    VerticalRes = enum
        Y240Lines = 0,
        Y480Lines = 1

    VMode = enum
        Ntsc = 0,
        Pal = 1

    DisplayDepth = enum
        D15Bits = 0,
        D24Bits = 1

    DmaDirection = enum
        Off = 0,
        Fifo = 1,
        CpuToGp0 = 2,
        VRamToCpu = 3

    Gp0Mode = enum
        Command,
        ImageLoad

    CommandBuffer = ref object
        buffer: array[12, uint32]
        len: uint8

    ImageBuffer = ref object
        buffer: array[VRAM_SIZE_PIXELS, uint16]
        top_left: tuple[a: uint16, b: uint16]
        resolution: tuple[a: uint16, b: uint16]
        index: uint32

proc clear_command_buffer(buffer: CommandBuffer) =
    buffer.len = 0'u8

proc push_word_command_buffer(buffer: CommandBuffer, word: uint32) =
    buffer.buffer[buffer.len] = word
    buffer.len += 1

proc push_word_image_buffer(buffer: ImageBuffer, word: uint32) =
    buffer.buffer[buffer.index] = uint16(word and 0xFFFF)
    buffer.index += 1
    buffer.buffer[buffer.index] = uint16(word shr 16)
    buffer.index += 1

proc reset_image_buffer(buffer: ImageBuffer, x: uint16, y: uint16, width: uint16, height: uint16) =
    buffer.top_left = (x, y)
    buffer.resolution = (width, height)
    buffer.index = 0'u32

proc clear_image_buffer(buffer: ImageBuffer) =
    buffer.top_left = (0'u16, 0'u16)
    buffer.resolution = (0'u16, 0'u16)
    buffer.index = 0'u32

proc gp0_nop() =
    stdout.write ""

var page_base_x: uint8
var page_base_y: uint8
var semi_transparency: uint8
var texture_depth: TextureDepth
var dithering: bool
var draw_to_display: bool
var force_set_mask_bit: bool
var preserve_masked_pixels: bool
var field: Field
var texture_disable: bool
var hres: uint32
var vres: VerticalRes
var vmode: VMode
var display_depth: DisplayDepth
var interlaced: bool
var display_disabled: bool
var gpu_interrupt: bool
var dma_direction: DmaDirection

var rectangle_texture_x_flip: bool
var rectangle_texture_y_flip: bool

var texture_window_x_mask: uint8
var texture_window_y_mask: uint8
var texture_window_x_offset: uint8
var texture_window_y_offset: uint8
var drawing_area_left: uint16
var drawing_area_top: uint16
var drawing_area_right: uint16
var drawing_area_bottom: uint16
var drawing_x_offset: int16
var drawing_y_offset: int16
var display_vram_x_start: uint16
var display_vram_y_start: uint16
var display_horiz_start: uint16
var display_horiz_end: uint16
var display_line_start: uint16
var display_line_end: uint16

var gp0_instruction: uint32
var gp1_instruction: uint32

var gp0_command = CommandBuffer()
var gp0_words_remaining: uint32
var gp0_command_method = gp0_nop
var gp0_mode: Gp0Mode

var image_buffer = ImageBuffer()

var response: uint32

var cycles: uint32
var display_line: uint32
var vblank_interrupt: bool

proc gpu_read*(): uint32 =
    let resp = response
    response = 0x00'u32
    return resp

proc new_position_from_gp0(value: uint32): tuple[x: GLshort, y: GLshort, z: GLshort] =
    let x = cast[int16](value and 0xFFFF)
    let y = cast[int16](value shr 16)
    return (cast[GLshort](x + drawing_x_offset), cast[GLshort](y + drawing_y_offset), 0.GLshort)

proc new_color_from_gp0(value: uint32): tuple[r: GLubyte, g: GLubyte, b: GLubyte] =
    let r = cast[uint8](value and 0xFF)
    let g = cast[uint8]((value shr 8) and 0xFF)
    let b = cast[uint8]((value shr 16) and 0xFF)
    return (cast[GLubyte](r), cast[GLubyte](g), cast[GLubyte](b))

proc position_from_gp0(value: uint32): tuple[x: int16, y: int16] =
    let x = cast[int16](value and 0xFFFF)
    let y = cast[int16](value shr 16)
    return (x + drawing_x_offset, y + drawing_y_offset)

proc color_from_gp0(value: uint32): tuple[r: uint8, g: uint8, b: uint8] =
    let r = cast[uint8](value and 0xFF)
    let g = cast[uint8]((value shr 8) and 0xFF)
    let b = cast[uint8]((value shr 16) and 0xFF)
    return (r, g, b)

proc gp0_texture_coordinates(command: uint32): tuple[x: uint8, y: uint8] =
    let x = command and 0xFF
    let y = (command shr 8) and 0xFF
    return (uint8(x), uint8(y))

proc hres_from_fields(hr1: uint8, hr2: uint8): uint32 =
    let v = (hr2 and 1) or ((hr1 and 3) shl 1)
    return uint32(v)

proc gpu_status*(): uint32 =
    var r = 0'u32
    r = r or (uint32(page_base_x) shl 0)
    r = r or (uint32(page_base_y) shl 4)
    r = r or (uint32(semi_transparency) shl 5)
    r = r or (uint32(ord(texture_depth)) shl 7)
    if dithering:
        r = r or (1'u32 shl 9)
    else:
        r = r or (0'u32 shl 9)
    if draw_to_display:
        r = r or (1'u32 shl 10)
    else:
        r = r or (0'u32 shl 10)
    if force_set_mask_bit:
        r = r or (1'u32 shl 11)
    else:
        r = r or (0'u32 shl 11)
    if preserve_masked_pixels:
        r = r or (1'u32 shl 12)
    else:
        r = r or (0'u32 shl 12)
    r = r or (uint32(ord(field)) shl 13)

    if texture_disable:
        r = r or (1'u32 shl 15)
    else:
        r = r or (0'u32 shl 15)
    r = r or (uint32(hres) shl 16)
    r = r or (uint32(ord(vres)) shl 19)
    r = r or (uint32(ord(vmode)) shl 20)
    r = r or (uint32(ord(display_depth)) shl 21)
    if interlaced:
        r = r or (1'u32 shl 22)
    else:
        r = r or (0'u32 shl 22)
    if display_disabled:
        r = r or (1'u32 shl 23)
    else:
        r = r or (0'u32 shl 23)
    if gpu_interrupt:
        r = r or (1'u32 shl 24)
    else:
        r = r or (0'u32 shl 24)

    r = r or (1 shl 26)
    r = r or (1 shl 27)
    r = r or (1 shl 28)

    r = r or (uint32(ord(dma_direction)) shl 29)

    r = r or (0 shl 28)

    let dma_request = case dma_direction:
        of DmaDirection.Off: 0'u32
        of DmaDirection.Fifo: 1'u32
        of DmaDirection.CpuToGp0: (r shr 28) and 1
        of VRamToCpu: (r shr 27) and 1

    r = r or (uint32(dma_request) shl 25)
    return r

proc gp0_draw_mode() =
    page_base_x = uint8(gp0_instruction and 0xF)
    page_base_y = uint8((gp0_instruction shr 4) and 1)
    semi_transparency = uint8((gp0_instruction shr 5) and 3)

    texture_depth = case (gp0_instruction shr 7) and 3:
        of 0: TextureDepth.T4Bit
        of 1: TextureDepth.T8Bit
        of 2: TextureDepth.T15Bit
        else: quit("Unhandled texture depth", QuitSuccess)

    dithering = ((gp0_instruction shr 0) and 1) != 0
    draw_to_display = ((gp0_instruction shr 10) and 1) != 0
    texture_disable = ((gp0_instruction shr 11) and 1) != 0
    rectangle_texture_x_flip = ((gp0_instruction shr 12) and 1) != 0
    rectangle_texture_y_flip = ((gp0_instruction shr 13) and 1) != 0

proc gp1_reset() =
    gpu_interrupt = false

    page_base_x = 0'u8
    page_base_y = 0'u8
    semi_transparency = 0'u8
    texture_depth = TextureDepth.T4Bit
    texture_window_x_mask = 0'u8
    texture_window_y_mask = 0'u8
    texture_window_x_offset = 0'u8
    texture_window_y_offset = 0'u8
    dithering = false
    draw_to_display = false
    texture_disable = false
    rectangle_texture_x_flip = false
    rectangle_texture_y_flip = false
    drawing_area_left = 0'u16
    drawing_area_top = 0'u16
    drawing_area_right = 0'u16
    drawing_area_bottom = 0'u16
    drawing_x_offset = 0'i16
    drawing_y_offset = 0'i16
    force_set_mask_bit = false
    preserve_masked_pixels = false

    dma_direction = DmaDirection.Off

    display_disabled = false
    display_vram_x_start = 0'u16
    display_vram_y_start = 0'u16
    hres = hres_from_fields(0'u8, 0'u8)
    vres = VerticalRes.Y240Lines

    vmode = VMode.Ntsc
    interlaced = true
    display_horiz_start = 0x200'u16
    display_horiz_end = 0xC00'u16
    display_line_start = 0x10'u16
    display_line_end = 0x100'u16
    display_depth = DisplayDepth.D15Bits

proc tick_gpu*() =
    cycles += 1
    let ticks_per_line = case vmode:
        of VMode.Ntsc: 3412'u32
        of VMode.Pal: 3404'u32

    let lines_per_frame = case vmode:
        of VMode.Ntsc: 263'u32
        of VMode.Pal: 314'u32

    if cycles == ticks_per_line:
        display_line += 1
        cycles = 0

    if display_line == lines_per_frame:
        display_line = 0

    let vblank_int = (display_line < display_line_start) or (display_line >= display_line_end)

    if (not vblank_interrupt) and vblank_int:
        #discard
        pend_irq(30, Interrupt.VBlank)

    if vblank_interrupt and (not vblank_int):
        frame_counter += 1
        render_frame()

    vblank_interrupt = vblank_int


proc gp1_display_mode() =
    let hr1 = uint8(gp1_instruction and 3)
    let hr2 = uint8((gp1_instruction shr 6) and 1)
    hres = hres_from_fields(hr1, hr2)

    vres = case (gp1_instruction and 0x4) != 0:
        of false: VerticalRes.Y240Lines
        of true: VerticalRes.Y480Lines

    vmode = case (gp1_instruction and 0x8) != 0:
        of false: VMode.Ntsc
        of true: VMode.Pal

    display_depth = case (gp1_instruction and 0x10) != 0:
        of false: DisplayDepth.D24Bits
        of true: DisplayDepth.D15Bits

    interlaced = (gp1_instruction and 0x20) != 0

    if (gp1_instruction and 0x80) != 0: quit("Unsupported display mode " & gp1_instruction.toHex(), QuitSuccess)

proc gp1_dma_direction() =
    dma_direction = case gp1_instruction and 3:
        of 0: DmaDirection.Off
        of 1: DmaDirection.Fifo
        of 2: DmaDirection.CpuToGp0
        of 3: DmaDirection.VRamToCpu
        else: quit("unreachable", QuitSuccess)

proc gp0_drawing_area_top_left() =
    drawing_area_top = uint16((gp0_instruction shr 10) and 0x3FF'u16)
    drawing_area_left = uint16(gp0_instruction and 0x3FF'u16)

proc gp0_drawing_area_bottom_right() =
    drawing_area_bottom = uint16((gp0_instruction shr 10) and 0x3FF'u16)
    drawing_area_right = uint16(gp0_instruction and 0x3FF'u16)

proc gp0_drawing_offset() =
    let x = uint16(gp0_instruction and 0x7FF'u16)
    let y = uint16((gp0_instruction shr 11) and 0x7FF'u16)

    drawing_x_offset = cast[int16](x shl 5) shr 5
    drawing_y_offset = cast[int16](y shl 5) shr 5

    #frame_counter += 1
    #render_frame()

proc gp0_texture_window() =
    texture_window_x_mask = uint8(gp0_instruction and 0x1F)
    texture_window_y_mask = uint8((gp0_instruction shr 5) and 0x1F)
    texture_window_x_offset = uint8((gp0_instruction shr 10) and 0x1F)
    texture_window_y_offset = uint8((gp0_instruction shr 15) and 0x1F)

proc gp0_mask_bit_setting() =
    force_set_mask_bit = (gp0_instruction and 1) != 0
    preserve_masked_pixels = (gp0_instruction and 2) != 0

proc gp1_display_vram_start() =
    display_vram_x_start = uint16(gp1_instruction and 0x3FE'u16)
    display_vram_y_start = uint16((gp1_instruction shr 10) and 0x1FF'u16)

proc gp1_display_horizontal_range() =
    display_horiz_start = uint16(gp1_instruction and 0xFFF'u16)
    display_horiz_end = uint16((gp1_instruction shr 12) and 0xFFF'u16)

proc gp1_display_vertical_range() =
    display_line_start = uint16(gp1_instruction and 0x3FF'u16)
    display_line_end = uint16((gp1_instruction shr 10) and 0x3FF'u16)

proc gp0_quad_mono_opaque() =
    {.gcsafe.}:
        let positions = [
            position_from_gp0(gp0_command.buffer[1]),
            position_from_gp0(gp0_command.buffer[2]),
            position_from_gp0(gp0_command.buffer[3]),
            position_from_gp0(gp0_command.buffer[4])
            ]

        let color = color_from_gp0(gp0_command.buffer[0])
        let colors = [color, color, color, color]

        push_quad(positions, colors)

proc gp0_clear_cache() =
    stdout.write "" # not implemented yet

proc gp0_image_load() =
    {.gcsafe.}:
        let pos = gp0_command.buffer[1]
        let x = uint16(pos and 0xFFFF'u16)
        let y = uint16(pos shr 16)
        let res = gp0_command.buffer[2]

        let width = res and 0xFFFF'u32
        let height = res shr 16
        var imgsize = width * height
        imgsize = (imgsize + 1) and (not 1'u32)
        gp0_words_remaining = imgsize div 2
        reset_image_buffer(image_buffer, x, y, uint16(width), uint16(height))
        gp0_mode = Gp0Mode.ImageLoad

proc gp1_display_enable() =
    display_disabled = (gp1_instruction and 1) != 0

proc gp0_image_store() =
    {.gcsafe.}:
        let res = gp0_command.buffer[2]
        let width = res and 0xFFFF'u32

        let height = res shr 16

        #echo "Unhandled image store ", width, "x", height

proc gp0_quad_shaded_opaque() =
    {.gcsafe.}:
        let positions = [
            position_from_gp0(gp0_command.buffer[1]),
            position_from_gp0(gp0_command.buffer[3]),
            position_from_gp0(gp0_command.buffer[5]),
            position_from_gp0(gp0_command.buffer[7])
            ]

        let colors = [
            color_from_gp0(gp0_command.buffer[0]),
            color_from_gp0(gp0_command.buffer[2]),
            color_from_gp0(gp0_command.buffer[4]),
            color_from_gp0(gp0_command.buffer[6])
            ]

        push_quad(positions, colors)

proc gp0_triangle_shaded_opaque() =
    {.gcsafe.}:
        let positions = [
            position_from_gp0(gp0_command.buffer[1]),
            position_from_gp0(gp0_command.buffer[3]),
            position_from_gp0(gp0_command.buffer[5])
            ]

        let colors = [
            color_from_gp0(gp0_command.buffer[0]),
            color_from_gp0(gp0_command.buffer[2]),
            color_from_gp0(gp0_command.buffer[4])
            ]

        push_triangle(positions, colors)

proc gp0_quad_texture_blend_opaque() =
    {.gcsafe.}:
        let positions = [
            position_from_gp0(gp0_command.buffer[1]),
            position_from_gp0(gp0_command.buffer[3]),
            position_from_gp0(gp0_command.buffer[5]),
            position_from_gp0(gp0_command.buffer[7])
            ]

        #let color = color_from_gp0(gp0_command.buffer[0])

        set_clut(gp0_command.buffer[2] shr 16)
        set_draw_params(gp0_command.buffer[4] shr 16)
        let (tex_x, tex_y) = gp0_texture_coordinates(gp0_command.buffer[2])

        push_texture_quad(positions, 255'u8, tex_x, tex_y)

proc gp0_fill_rectangle() =
    {.gcsafe.}:
        let color = color_from_gp0(gp0_command.buffer[0])
        let position = position_from_gp0(gp0_command.buffer[1])
        let size = position_from_gp0(gp0_command.buffer[2])
        renderer_fill_rectangle(position, size, color)

proc gp0_mono_rect_var_opaque() =
    {.gcsafe.}:
        let colors = [
            color_from_gp0(gp0_command.buffer[0]),
            color_from_gp0(gp0_command.buffer[0]),
            color_from_gp0(gp0_command.buffer[0]),
            color_from_gp0(gp0_command.buffer[0])
            ]
        let size = position_from_gp0(gp0_command.buffer[2])
        var positions = [
            position_from_gp0(gp0_command.buffer[1]),
            position_from_gp0(gp0_command.buffer[1]),
            position_from_gp0(gp0_command.buffer[1]),
            position_from_gp0(gp0_command.buffer[1])
            ]

        positions[1][0] += size[0]
        positions[2][1] += size[1]
        positions[3][0] += size[0]
        positions[3][1] += size[1]

        push_quad(positions, colors)

proc gp0_dot_opaque() =
    {.gcsafe.}:
        let colors = [
            color_from_gp0(gp0_command.buffer[0]),
            color_from_gp0(gp0_command.buffer[0]),
            color_from_gp0(gp0_command.buffer[0]),
            color_from_gp0(gp0_command.buffer[0])
            ]
        var positions = [
            position_from_gp0(gp0_command.buffer[1]),
            position_from_gp0(gp0_command.buffer[1]),
            position_from_gp0(gp0_command.buffer[1]),
            position_from_gp0(gp0_command.buffer[1])
            ]
        positions[1][0] += 1
        positions[2][1] += 1
        positions[3][0] += 1
        positions[3][1] += 1
        push_quad(positions, colors)

proc gp0_mono_rect_8_8_opaque() =
    {.gcsafe.}:
        let colors = [
            color_from_gp0(gp0_command.buffer[0]),
            color_from_gp0(gp0_command.buffer[0]),
            color_from_gp0(gp0_command.buffer[0]),
            color_from_gp0(gp0_command.buffer[0])
            ]
        let top_left = position_from_gp0(gp0_command.buffer[1])
        var positions = [
            top_left,
            top_left,
            top_left,
            top_left
            ]
        positions[1][0] += 8
        positions[2][1] += 8
        positions[3][0] += 8
        positions[3][1] += 8
        push_quad(positions, colors)

proc gp0_mono_rect_16_16_opaque() =
    {.gcsafe.}:
        let colors = [
            color_from_gp0(gp0_command.buffer[0]),
            color_from_gp0(gp0_command.buffer[0]),
            color_from_gp0(gp0_command.buffer[0]),
            color_from_gp0(gp0_command.buffer[0])
            ]
        let top_left = position_from_gp0(gp0_command.buffer[1])
        var positions = [
            top_left,
            top_left,
            top_left,
            top_left
            ]
        positions[1][0] += 16
        positions[2][1] += 16
        positions[3][0] += 16
        positions[3][1] += 16
        push_quad(positions, colors)

proc gp1_get_gpu_info() =
    response = 0x01'u32

proc gp1_acknowledge_irq() =
    gpu_interrupt = false

proc gp1_reset_command_buffer() =
    clear_command_buffer(gp0_command)
    gp0_words_remaining = 0
    gp0_mode = Gp0Mode.Command

proc gp0*(value: uint32) =
    if gp0_words_remaining == 0:
        let opcode = (value shr 24) and 0xFF
        gp0_instruction = value

        let (command_len, command_method) = case opcode:
            of 0x00: (1'u32, gp0_nop)
            of 0x01: (1'u32, gp0_clear_cache)
            of 0x02: (3'u32, gp0_fill_rectangle)
            of 0x04 .. 0x1E: (1'u32, gp0_nop)
            of 0x20: (4'u32, gp0_nop)
            of 0x28: (5'u32, gp0_quad_mono_opaque)
            of 0x2C: (9'u32, gp0_quad_texture_blend_opaque)
            of 0x30: (6'u32, gp0_triangle_shaded_opaque)
            of 0x38: (8'u32, gp0_quad_shaded_opaque)
            of 0x3C: (12'u32, gp0_nop)
            of 0x60: (3'u32, gp0_mono_rect_var_opaque)
            of 0x62: (3'u32, gp0_mono_rect_var_opaque) # actually semi
            of 0x68: (2'u32, gp0_dot_opaque)
            of 0x6A: (2'u32, gp0_dot_opaque) # actually semi
            of 0x70: (2'u32, gp0_mono_rect_8_8_opaque)
            of 0x72: (2'u32, gp0_mono_rect_8_8_opaque) # actually semi
            of 0x74: (3'u32, gp0_nop)
            of 0x78: (2'u32, gp0_mono_rect_16_16_opaque)
            of 0x7A: (2'u32, gp0_mono_rect_16_16_opaque) # actually semi
            of 0x7F: (3'u32, gp0_nop)
            of 0xA0: (3'u32, gp0_image_load)
            of 0xC0: (3'u32, gp0_image_store)
            of 0xE1: (1'u32, gp0_draw_mode)
            of 0xE2: (1'u32, gp0_texture_window)
            of 0xE3: (1'u32, gp0_drawing_area_top_left)
            of 0xE4: (1'u32, gp0_drawing_area_bottom_right)
            of 0xE5: (1'u32, gp0_drawing_offset)
            of 0xE6: (1'u32, gp0_mask_bit_setting)
            else: quit("Unhandled GP0 command " & gp0_instruction.toHex(), QuitSuccess)

        gp0_words_remaining = command_len
        gp0_command_method = command_method
        clear_command_buffer(gp0_command)

    gp0_words_remaining -= 1

    case gp0_mode:
        of Gp0Mode.Command:
            push_word_command_buffer(gp0_command, value)
            if gp0_words_remaining == 0:
                gp0_command_method()
        of Gp0Mode.ImageLoad:
            push_word_image_buffer(image_buffer, value)
            if gp0_words_remaining == 0:
                renderer_load_image(image_buffer.top_left, image_buffer.resolution, image_buffer.buffer, image_buffer.index)
                clear_image_buffer(image_buffer)
                gp0_mode = Gp0Mode.Command

proc gp1*(value: uint32) =
    gp1_instruction = value
    let opcode = (value shr 24) and 0xFF

    case opcode:
        of 0x00: gp1_reset()
        of 0x01: gp1_reset_command_buffer()
        of 0x02: gp1_acknowledge_irq()
        of 0x03: gp1_display_enable()
        of 0x04: gp1_dma_direction()
        of 0x05: gp1_display_vram_start()
        of 0x06: gp1_display_horizontal_range()
        of 0x07: gp1_display_vertical_range()
        of 0x08: gp1_display_mode()
        of 0x10: gp1_get_gpu_info()
        else: quit("Unhandled GP1 command " & gp1_instruction.toHex(), QuitSuccess)
