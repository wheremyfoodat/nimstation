import csfml, times
import cdrom, bus

const VERTEX_BUFFER_LEN = 64*1024
const VRAM_SIZE_PIXELS = 1024 * 512

var screenWidth: cint = 1024
var screenHeight: cint = 512
let videoMode = videoMode(screenWidth, screenHeight)
let settings = contextSettings(depth=32, antialiasing=8)
var window = newRenderWindow(videoMode, "NimStation", settings=settings)
window.clear Black
window.display()

var vram_texture = newTexture(screenWidth, screenHeight)
var vram_sprite = newSprite(vram_texture)

var temp_textures = newSeq[Texture](0)
var temp_sprites = newSeq[Sprite](0)

var vertex_array = newVertexArray(PrimitiveType.Triangles)
var nvertices = 0'u32

var textures = newVertexArray(PrimitiveType.Triangles)
var ntextures = 0'u32

var clut_x: uint32
var clut_y: uint32

var page_x: uint32
var page_y: uint32

var texture_depth: uint32

var vram: array[512, array[1024, uint16]]

var frame_time: float
var frames: uint8

proc renderer_load_image*(top_left: tuple[a: uint16, b: uint16], resolution: tuple[a: uint16, b: uint16], buffer: array[VRAM_SIZE_PIXELS, uint16]) =
    let x1 = cast[uint32](top_left[0])
    let y1 = cast[uint32](top_left[1])
    let width = cast[uint32](resolution[0])
    let height = cast[uint32](resolution[1])
    var pixels:  seq[uint8]

    if (height != 0) and (width != 0):
        var pixel = 0'u16
        for y in 0'u32 ..< height:
            for x in 0'u32 ..< width:
                pixel = buffer[y*width + x]
                vram[y1 + y][x1 + x] = pixel

                pixels.add(uint8((pixel shl 3) and 0xF8))
                pixels.add(uint8((pixel shr 2) and 0xF8))
                pixels.add(uint8((pixel shr 7) and 0xF8))
                pixels.add(255)

        updateFromPixels(vram_texture, pixels[0].addr, cint(width), cint(height), cint(x1), cint(y1))

proc renderer_fill_rectangle*(position: tuple[x: int16, y: int16], size: tuple[x: int16, y: int16],  color: tuple[r: uint8, g: uint8, b: uint8]) =
    var fill_color = 0'u16
    fill_color = fill_color or ((color[0] shr 3) shl 10)
    fill_color = fill_color or ((color[1] shr 3) shl 5)
    fill_color = fill_color or (color[0] shl 3)

    if (size[1] != 0) and (size[0] != 0):
        var pixels = newSeq[uint8](0)

        for y in (0 ..< size[1]):
            for x in (0 ..< size[0]):
                vram[(position[1] + y) and 0x1FF][(position[0] + x) and 0x3FF] = fill_color
                pixels.add(color.r)
                pixels.add(color.g)
                pixels.add(color.b)
                pixels.add(255)
        updateFromPixels(vram_texture, pixels[0].addr, cint(size[0]), cint(size[1]), cint(position[0]), cint(position[1]))

proc set_clut*(clut: uint32) =
    clut_x = (clut and 0x3F) shl 4
    clut_y = (clut shr 6) and 0x1FF'u32
    #echo "set clut_x to ", clut_x, ", clut y to ", clut_y

proc set_draw_params*(params: uint32) =
    page_x = (params and 0xF'u32) shl 6
    page_y = ((params shr 4) and 1) shl 8
    texture_depth = (params shr 7) and 3
    #echo "set draw params ", page_x, " ", page_y, " ", texture_depth

proc get_texel_4bit(x: uint32, y: uint32): uint16 =
    let texel = vram[(page_y + y) and 0x1FF][(page_x + (x div 4)) and 0x3FF]
    let index = (texel shr ((x mod 4) * 4)) and 0xF
    return vram[clut_y][clut_x + index]

proc get_texel_8bit(x: uint32, y: uint32): uint16 =
    let texel = vram[(page_y + y) and 0x1FF][(page_x + (x div 2)) and 0x3FF]
    let index = (texel shr ((x mod 2) * 4)) and 0xFF
    return vram[clut_y][clut_x + index]

proc get_texel_16bit(x: uint32, y: uint32): uint16 =
    return vram[page_y + y][page_x + x]

proc parse_events*() =
    #discard
    var event: Event
    while window.pollEvent(event):
        case event.kind:
            of EventType.Closed:
                window.close()
                vertex_array.destroy()
                textures.destroy()
                vram_sprite.destroy()
                quit()
            of EventType.KeyPressed:
                case event.key.code:
                    of KeyCode.F1:
                        cdrom_debug = not cdrom_debug
                    of KeyCode.F2:
                        dump_wram()
                    of KeyCode.F3:
                        dump_regs = not dump_regs
                    else: discard
            else: discard

proc render_frame*() =
    if (nvertices > 0'u32) or (ntextures > 0'u32):
        #window.clear Black
        window.draw(vram_sprite)

    if nvertices > 0:
        window.draw(vertex_array)

    if ntextures > 0:
        for sprite in temp_sprites:
            window.draw(sprite)

    if (nvertices != 0) or (ntextures != 0):
        window.display()
        vertex_array.clear()
        temp_textures.setLen(0)
        temp_sprites.setLen(0)
        nvertices = 0
        ntextures = 0

    frames += 1

    if (cpuTime() - frame_time) >= 1:
        frame_time = cpuTime()
        window.title = "NimStation - " & $frames & "fps"
        frames = 0



proc push_triangle*(vertices: array[3, Vertex]) =
    #discard
    if (nvertices + 3) > VERTEX_BUFFER_LEN:
        render_frame()

    for i in 0 ..< 3:
        vertex_array.append vertices[i]
        nvertices += 1

proc push_quad*(vertices: array[4, Vertex]) =
    #discard
    if (nvertices + 6) > VERTEX_BUFFER_LEN:
        render_frame()

    for i in 0 ..< 3:
        vertex_array.append vertices[i]
        nvertices += 1

    for i in 1 ..< 4:
        vertex_array.append vertices[i]
        nvertices += 1

proc push_texture*(positions: array[4, tuple[x: int16, y: int16]], tex_x: uint8, tex_y: uint8, opacity: uint8) =
    #discard
    let x_len = cint(abs(positions[1].x -% positions[0].x))
    let y_len = cint(abs(positions[2].y -% positions[0].y))

    if (x_len != 0) and (y_len != 0):
        var quad_texture = newTexture(x_len, y_len)
        var quad_sprite = newSprite(quad_texture)
        quad_sprite.position = vec2(cint(positions[0].x), cint(positions[0].y))

        var pixels = newSeq[uint8](0)
        var pixel = 0'u16
        for y in 0 ..< y_len:
            for x in 0 ..< x_len:
                pixel = case texture_depth:
                    of 0: get_texel_4bit(uint32(x + int(tex_x)), uint32(y + int(tex_y)))
                    of 1: get_texel_8bit(uint32(x + int(tex_x)), uint32(y + int(tex_y)))
                    of 2: get_texel_16bit(uint32(x + int(tex_x)), uint32(y + int(tex_y)))
                    else: 0x00'u16
                let r = (pixel shl 3) and 0xF8
                let g = (pixel shr 2) and 0xF8
                let b = (pixel shr 7) and 0xF8

                if pixel != 0:
                    pixels.add(uint8(r))
                    pixels.add(uint8(g))
                    pixels.add(uint8(b))
                    pixels.add(255'u8)
                else:
                    pixels.add(0'u8)
                    pixels.add(0'u8)
                    pixels.add(0'u8)
                    pixels.add(0'u8)
        updateFromPixels(quad_texture, pixels[0].addr, x_len, y_len, cint(0), cint(0))
        temp_textures.add(quad_texture)
        temp_sprites.add(quad_sprite)
        ntextures += 1
