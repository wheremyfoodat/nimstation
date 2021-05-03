import strutils, bitops
import gte_tests
type
    Matrix = enum
        Rotation = 0,
        Light = 1,
        Color = 2
        Invalid = 3

    ControlVector = enum
        Translation = 0,
        BackgroundColor = 1,
        FarColor = 2,
        Zero = 3

const UNR_TABLE = [
    0xff, 0xfd, 0xfb, 0xf9, 0xf7, 0xf5, 0xf3, 0xf1,
    0xef, 0xee, 0xec, 0xea, 0xe8, 0xe6, 0xe4, 0xe3,
    0xe1, 0xdf, 0xdd, 0xdc, 0xda, 0xd8, 0xd6, 0xd5,
    0xd3, 0xd1, 0xd0, 0xce, 0xcd, 0xcb, 0xc9, 0xc8,
    0xc6, 0xc5, 0xc3, 0xc1, 0xc0, 0xbe, 0xbd, 0xbb,
    0xba, 0xb8, 0xb7, 0xb5, 0xb4, 0xb2, 0xb1, 0xb0,
    0xae, 0xad, 0xab, 0xaa, 0xa9, 0xa7, 0xa6, 0xa4,
    0xa3, 0xa2, 0xa0, 0x9f, 0x9e, 0x9c, 0x9b, 0x9a,
    0x99, 0x97, 0x96, 0x95, 0x94, 0x92, 0x91, 0x90,
    0x8f, 0x8d, 0x8c, 0x8b, 0x8a, 0x89, 0x87, 0x86,
    0x85, 0x84, 0x83, 0x82, 0x81, 0x7f, 0x7e, 0x7d,
    0x7c, 0x7b, 0x7a, 0x79, 0x78, 0x77, 0x75, 0x74,
    0x73, 0x72, 0x71, 0x70, 0x6f, 0x6e, 0x6d, 0x6c,
    0x6b, 0x6a, 0x69, 0x68, 0x67, 0x66, 0x65, 0x64,
    0x63, 0x62, 0x61, 0x60, 0x5f, 0x5e, 0x5d, 0x5d,
    0x5c, 0x5b, 0x5a, 0x59, 0x58, 0x57, 0x56, 0x55,
    0x54, 0x53, 0x53, 0x52, 0x51, 0x50, 0x4f, 0x4e,
    0x4d, 0x4d, 0x4c, 0x4b, 0x4a, 0x49, 0x48, 0x48,
    0x47, 0x46, 0x45, 0x44, 0x43, 0x43, 0x42, 0x41,
    0x40, 0x3f, 0x3f, 0x3e, 0x3d, 0x3c, 0x3c, 0x3b,
    0x3a, 0x39, 0x39, 0x38, 0x37, 0x36, 0x36, 0x35,
    0x34, 0x33, 0x33, 0x32, 0x31, 0x31, 0x30, 0x2f,
    0x2e, 0x2e, 0x2d, 0x2c, 0x2c, 0x2b, 0x2a, 0x2a,
    0x29, 0x28, 0x28, 0x27, 0x26, 0x26, 0x25, 0x24,
    0x24, 0x23, 0x22, 0x22, 0x21, 0x20, 0x20, 0x1f,
    0x1e, 0x1e, 0x1d, 0x1d, 0x1c, 0x1b, 0x1b, 0x1a,
    0x19, 0x19, 0x18, 0x18, 0x17, 0x16, 0x16, 0x15,
    0x15, 0x14, 0x14, 0x13, 0x12, 0x12, 0x11, 0x11,
    0x10, 0x0f, 0x0f, 0x0e, 0x0e, 0x0d, 0x0d, 0x0c,
    0x0c, 0x0b, 0x0a, 0x0a, 0x09, 0x09, 0x08, 0x08,
    0x07, 0x07, 0x06, 0x06, 0x05, 0x05, 0x04, 0x04,
    0x03, 0x03, 0x02, 0x02, 0x01, 0x01, 0x00, 0x00,
    0x00
    ]

# GTE regs
# Control
var ofx: int32 # Screen offset X
var ofy: int32 # Screen offset Y
var h: uint16 # Projection plane distance
var dqa: int16 # Depth queing coeffient
var dqb: int32 # Depth queing offset
var zsf3: int16 # Scale factor for average of 3 Z values
var zsf4: int16 # Scale factor for average of 4 Z values
var matrices: array[3, array[3, array[3, int16]]] # Three 3x3 signed matrices
var control_vectors: array[4, array[3, int32]] # Five 3x signed words control vectors
var flags: uint32 # Overflow flags

# Data
var v: array[4, array[3, int16]] # Vectors 3x3 signed
var mac: array[4, int32] # Accumulators
var otz: uint16 # Z average
var rgb: (uint8, uint8, uint8, uint8) # RGB color
var ir: array[4, int16] # Accumulators
var xy_fifo: array[4, (int16, int16)]
var z_fifo: array[4, uint16]
var rgb_fifo: array[3, (uint8, uint8, uint8, uint8)]
var lzcs: uint32 # Input value
var lzcr: uint8 = 32'u8 # Numbers for leading zeroes in lzsc
var reg_23: uint32

var config_shift: uint8
var config_clamp_negative: bool
var config_matrix: Matrix
var config_vector_mul: uint8
var config_vector_add: ControlVector

proc control_vector_from_command(command: uint32): ControlVector =
    case ((command shr 13) and 3):
        of 0: return ControlVector.Translation
        of 1: return ControlVector.BackgroundColor
        of 2: return ControlVector.FarColor
        of 3: return ControlVector.Zero
        else: quit("unreachable", QuitSuccess)

proc matrix_from_command(command: uint32): Matrix =
    case ((command shr 17) and 3):
        of 0: return Matrix.Rotation
        of 1: return Matrix.Light
        of 2: return Matrix.Color
        of 3: return Matrix.Invalid
        else: quit("unreachable", QuitSuccess)

proc config_from_command(command: uint32) =
    if (command and (1 shl 19)) != 0:
        config_shift = 12
    else:
        config_shift = 0

    config_clamp_negative = (command and (1 shl 10)) != 0
    config_vector_mul = uint8((command shr 15) and 3)
    config_matrix = matrix_from_command(command)
    config_vector_add = control_vector_from_command(command)

proc set_flag(bit: uint8) =
    flags = flags or (1'u32 shl bit)

proc i64_to_i44(flag: uint8, value: int64): int64 =
    if value > 0x7FFFFFFFFFF:
        set_flag(30'u8 - flag)
    elif value < (-0x80000000000):
        set_flag(27'u8 - flag)

    return (value shl (64 - 44)) shr (64 - 44)

proc i32_to_i16_saturate(flag: uint8, value: int32): int16 =
    var min = 0'i32
    if not config_clamp_negative:
        min = cast[int32](int16(-32768))

    let max = cast[int32](int16(32767))

    if value > max:
        set_flag(24'u8 - flag)
        return cast[int16](max)
    elif value < min:
        set_flag(24'u8 - flag)
        return cast[int16](min)
    else:
        return cast[int16](value)

proc check_mac_overflow(value: int64) =
    if value < (-1*0x80000000):
        set_flag(15)
    elif value > int64(0x7FFFFFFF):
        set_flag(16)

proc reciprocal(d: uint16): uint32 =
    let index = ((d and 0x7FFF) + 0x40) shr 7
    let factor = cast[int32](UNR_TABLE[index]) + 0x101
    let d = cast[int32](d or 0x8000)
    let tmp = ((d * (factor * -1) ) + 0x80) shr 8
    let r = ((factor * (0x20000 + tmp)) + 0x80) shr 8
    return cast[uint32](r)

proc divide(numerator: uint16, divisor: uint16): uint32 =
    var shift = 0
    if divisor == 0:
        shift = 16
    else:
        shift = countLeadingZeroBits(divisor)

    let n = cast[uint64](numerator) shl shift
    let d = divisor shl shift

    let reciprocal = cast[uint64](reciprocal(d))

    let res = (n * reciprocal + 0x8000) shr 16

    if res <= 0x1FFFF:
        return cast[uint32](res)
    else:
        return 0x1FFFF

proc i32_to_i11_saturate(flag: uint8, value: int32): int16 =
    if value < (-0x400):
        set_flag(14'u8 - flag)
        return -0x400
    elif value > 0x3FF:
        set_flag(14'u8 - flag)
        return 0x3FF
    else:
        return cast[int16](value)

proc depth_queuing(projection_factor: uint32) =
    let factor = cast[int64](projection_factor)
    let idqa = cast[int64](dqa)
    let idqb = cast[int64](dqb)

    var depth = idqb + idqa * factor
    check_mac_overflow(depth)
    mac[0] = cast[int32](depth)

    depth = depth shr 12

    if depth < 0:
        set_flag(12)
        ir[0] = 0
    elif depth > 4096:
        set_flag(12)
        ir[0] = 4096
    else:
        ir[0] = cast[int16](depth)

proc mac_to_ir() =
    ir[1] = i32_to_i16_saturate(0, mac[1])
    ir[2] = i32_to_i16_saturate(1, mac[2])
    ir[3] = i32_to_i16_saturate(2, mac[3])

proc multiply_matrix_by_vector(matrix: Matrix, vector_index: uint8, control_vector: ControlVector) =
    if matrix == Matrix.Invalid:
        quit("GTE multiplication with invalid matrix", QuitSuccess)

    if control_vector == ControlVector.FarColor:
        quit("GTE multiplication with far color vector", QuitSuccess)

    let mat = ord(matrix)
    let crv = ord(control_vector)

    for r in 0 ..< 3:
        var res = cast[int64](control_vectors[crv][r]) shl 12
        for c in 0 ..< 3:
            let vv = cast[int32](v[vector_index][c])
            let m = cast[int32](matrices[mat][r][c])
            let product = vv * m
            res = i64_to_i44(uint8(r), res + cast[int64](product))
        mac[r + 1] = cast[int32](res shr config_shift)
    mac_to_ir()

proc do_rtp(vector_index: uint8): uint32 =
    var z_shifted: int32
    let rm = ord(Matrix.Rotation)
    let tr = ord(ControlVector.Translation)

    for r in 0'u8 ..< 3'u8:
        var res = cast[int64](control_vectors[tr][r]) shl 12

        for c in 0'u8 ..< 3'u8:
            let vv = cast[int32](v[vector_index][c])
            let m = cast[int32](matrices[rm][r][c])

            let rot = vv * m

            res = i64_to_i44(c, cast[int64](res + rot))
        mac[r + 1] = cast[int32](res shr config_shift)
        z_shifted = cast[int32](res shr 12)

    var val = mac[1]
    ir[1] = i32_to_i16_saturate(0, val)
    val = mac[2]
    ir[2] = i32_to_i16_saturate(1, val)

    var min = cast[int32](int16(-32768))
    let max = cast[int32](32767'i16)

    if (z_shifted > max) or (z_shifted < min):
        set_flag(22)

    if config_clamp_negative:
        min = 0'i32

    val = mac[3]

    if val < min:
        ir[3] = cast[int16](min)
    elif val > max:
        ir[3] = cast[int16](max)
    else:
        ir[3] = cast[int16](val)

    var z_saturated = 0'u16
    if z_shifted < 0:
        set_flag(18)
    elif z_shifted > cast[int32](0xFFFF'u16):
        set_flag(18)
        z_saturated = 0xFFFF'u16
    else:
        z_saturated = cast[uint16](z_shifted)

    z_fifo[0] = z_fifo[1]
    z_fifo[1] = z_fifo[2]
    z_fifo[2] = z_fifo[3]
    z_fifo[3] = z_saturated

    var projection_factor = 0x1FFFF'u32
    if z_saturated > (h div 2'u16):
        projection_factor = divide(h, z_saturated)
    else:
        set_flag(17)

    let factor = cast[int64](projection_factor)
    let x = cast[int64](ir[1])
    let y = cast[int64](ir[2])
    let temp_ofx = cast[int64](ofx)
    let temp_ofy = cast[int64](ofy)

    var screen_x = x * factor + temp_ofx
    var screen_y = y * factor + temp_ofy

    check_mac_overflow(screen_x)
    check_mac_overflow(screen_y)

    screen_x = cast[int32](screen_x shr 16)
    screen_y = cast[int32](screen_y shr 16)

    xy_fifo[3] = (i32_to_i11_saturate(0'u8, cast[int32](screen_x)), i32_to_i11_saturate(1'u8, cast[int32](screen_y)))
    xy_fifo[0] = xy_fifo[1]
    xy_fifo[1] = xy_fifo[2]
    xy_fifo[2] = xy_fifo[3]

    return projection_factor

proc i64_to_otz(average: int64): uint16 =
    let value = average shr 12
    if value < 0:
        set_flag(18)
        return 0x0000'u16
    elif value > 0xFFFF:
        set_flag(18)
        return 0xFFFF'u16
    else:
        return cast[uint16](value)

proc mac_to_color(mac: int32, which: uint8): uint8 =
    let c = mac shr 4
    if c < 0:
        set_flag(21'u8 - which)
        return 0'u8
    elif c > 0xFF:
        set_flag(21'u8 - which)
        return 0xFF'u8
    else:
        return cast[uint8](c)

proc mac_to_rgb_fifo() =
    let r = mac_to_color(mac[1], 0)
    let g = mac_to_color(mac[2], 1)
    let b = mac_to_color(mac[3], 2)

    let (_, _, _, x) = rgb
    rgb_fifo[0] = rgb_fifo[1]
    rgb_fifo[1] = rgb_fifo[2]
    rgb_fifo[2] = (r, g, b, x)

proc cmd_dcpl() =
    let fc0 = ord(ControlVector.FarColor)
    let (r, g, b, _) = rgb
    let col_arr = [r, g, b]
    for i in 0'u8 ..< 3'u8:
        let fc = cast[int64](control_vectors[fc0][i]) shl 12
        let cur_ir = cast[int32](ir[i + 1])
        let col = cast[int32](col_arr[i]) shl 4
        let shading = cast[int64](col * cur_ir)
        var tmp = fc - shading
        tmp = cast[int32](i64_to_i44(cast[uint8](i), tmp) shr config_shift)
        let ir0 = cast[int64](ir[0])
        let prev_clamp = config_clamp_negative
        config_clamp_negative = false
        var res = cast[int64](i32_to_i16_saturate(i, cast[int32](tmp)))
        config_clamp_negative = prev_clamp
        res = i64_to_i44(i, shading + ir0 * res)
        mac[i + 1] = cast[int32](res shr config_shift)
    mac_to_ir()
    mac_to_rgb_fifo()

proc do_ncd(vector_index: uint8) =
    multiply_matrix_by_vector(Matrix.Light, vector_index, ControlVector.Zero)
    v[3][0] = ir[1]
    v[3][1] = ir[2]
    v[3][2] = ir[3]
    multiply_matrix_by_vector(Matrix.Color, 3, ControlVector.BackgroundColor)
    cmd_dcpl()

proc do_ncc(vector_index: uint8) =
    multiply_matrix_by_vector(Matrix.Light, vector_index, ControlVector.Zero)
    v[3][0] = ir[1]
    v[3][1] = ir[2]
    v[3][2] = ir[3]
    multiply_matrix_by_vector(Matrix.Color, 3, ControlVector.BackgroundColor)
    let (r, g, b, _) = rgb
    let col_arr = [r, g, b]

    for i in 0 ..< 3:
        let col = cast[int32](col_arr[i]) shl 4
        let temp_ir = cast[int32](ir[i + 1])
        mac[i + 1] = (col * temp_ir) shr config_shift

    mac_to_ir()
    mac_to_rgb_fifo()

proc cmd_nclip() =
    var (x0, y0) = (cast[int32](xy_fifo[0][0]), cast[int32](xy_fifo[0][1]))
    var (x1, y1) = (cast[int32](xy_fifo[1][0]), cast[int32](xy_fifo[1][1]))
    var (x2, y2) = (cast[int32](xy_fifo[2][0]), cast[int32](xy_fifo[2][1]))

    let a = x0 * (y1 - y2)
    let b = x1 * (y2 - y0)
    let c = x2 * (y0 - y1)

    let sum = cast[int64](a) + cast[int64](b) + cast[int64](c)

    check_mac_overflow(sum)

    mac[0] = cast[int32](sum)

proc cmd_rtpt() =
    discard do_rtp(0)
    discard do_rtp(1)
    let projection_factor = do_rtp(2)
    depth_queuing(projection_factor)

proc cmd_ncds() =
    do_ncd(0)

proc cmd_mvmva() =
    v[3][0] = ir[1]
    v[3][1] = ir[2]
    v[3][2] = ir[3]
    multiply_matrix_by_vector(config_matrix, config_vector_mul, config_vector_add)

proc cmd_avsz3() =
    let z1 = cast[uint32](z_fifo[1])
    let z2 = cast[uint32](z_fifo[2])
    let z3 = cast[uint32](z_fifo[3])

    let sum = z1 + z2 + z3

    let temp_zsf3 = cast[int64](zsf3)
    let average = temp_zsf3 * cast[int64](sum)

    check_mac_overflow(average)
    mac[0] = cast[int32](average)
    otz = i64_to_otz(average)

proc cmd_avsz4() =
    let z0 = cast[uint32](z_fifo[0])
    let z1 = cast[uint32](z_fifo[1])
    let z2 = cast[uint32](z_fifo[2])
    let z3 = cast[uint32](z_fifo[3])

    let sum = z0 + z1 + z2 + z3

    let temp_zsf4 = cast[int64](zsf4)
    let average = temp_zsf4 * cast[int64](sum)

    check_mac_overflow(average)
    mac[0] = cast[int32](average)
    otz = i64_to_otz(average)

proc cmd_ncct() =
    do_ncc(0)
    do_ncc(1)
    do_ncc(2)

proc cmd_rtps() =
    let projection_factor = do_rtp(0)
    depth_queuing(projection_factor)

proc cmd_nccs() =
    do_ncc(0)


proc gte_command*(command: uint32) =
    let opcode = command and 0x3F
    config_from_command(command)
    flags = 0

    case opcode:
        of 0x01: cmd_rtps()     #Tested
        of 0x06: cmd_nclip()    #Tested
        of 0x12: cmd_mvmva()    #Tested
        of 0x13: cmd_ncds()     #Tested
        of 0x1B: cmd_nccs()     #No tests
        of 0x2D: cmd_avsz3()    #Tested
        of 0x2E: cmd_avsz4()    #No tests
        of 0x30: cmd_rtpt()     #Tested
        of 0x3F: cmd_ncct()
        else: quit("Unhandled GTE opcode " & opcode.toHex(), QuitSuccess)

    let msb = flags and 0x7F87E000
    if msb != 0:
        flags = flags or (1 shl 31)


proc gte_set_data*(reg: uint32, value: uint32) =
    let r = cast[uint8](value)
    let g = cast[uint8](value shr 8)
    let b = cast[uint8](value shr 16)
    let x = cast[uint8](value shr 24)

    let pos_x = cast[int16](value)
    let pos_y = cast[int16](value shr 16)

    case reg:
        of 0:
            v[0][0] = pos_x
            v[0][1] = pos_y
        of 1: v[0][2] = pos_x
        of 2:
            v[1][0] = pos_x
            v[1][1] = pos_y
        of 3: v[1][2] = pos_x
        of 4:
            v[2][0] = pos_x
            v[2][1] = pos_y
        of 5: v[2][2] = pos_x
        of 6: rgb = (r, g, b, x)
        of 7: otz = cast[uint16](value)
        of 8: ir[0] = pos_x
        of 9: ir[1] = pos_x
        of 10: ir[2] = pos_x
        of 11: ir[3] = pos_x
        of 12: xy_fifo[0] = (pos_x, pos_y)
        of 13: xy_fifo[1] = (pos_x, pos_y)
        of 14:
            xy_fifo[2] = (pos_x, pos_y)
            xy_fifo[3] = (pos_x, pos_y)
        of 15:
            xy_fifo[3] = (pos_x, pos_y)
            xy_fifo[0] = xy_fifo[1]
            xy_fifo[1] = xy_fifo[2]
            xy_fifo[2] = xy_fifo[3]
        of 16: z_fifo[0] = cast[uint16](value)
        of 17: z_fifo[1] = cast[uint16](value)
        of 18: z_fifo[2] = cast[uint16](value)
        of 19: z_fifo[3] = cast[uint16](value)
        of 20: rgb_fifo[0] = (r, g, b, x)
        of 21: rgb_fifo[1] = (r, g, b, x)
        of 22: rgb_fifo[2] = (r, g, b, x)
        of 23: reg_23 = value
        of 24: mac[0] = cast[int32](value)
        of 25: mac[1] = cast[int32](value)
        of 26: mac[2] = cast[int32](value)
        of 27: mac[3] = cast[int32](value)
        of 28:
            ir[0] = cast[int16]((value and 0x1F) shl 7)
            ir[1] = cast[int16](((value shr 5) and 0x1F) shl 7)
            ir[2] = cast[int16](((value shr 10) and 0x1F) shl 7)
        of 29: discard
        of 30:
            lzcs = value
            var temp = 0'u32
            if ((value shr 31) and 1) != 0:
                temp = not value
            else:
                temp = value
            if temp == 0:
                lzcr = 32'u8
            else:
                lzcr = cast[uint8](countLeadingZeroBits(temp))
        of 31: echo "Write to read-only GTE data register 31"
        else: quit("unreachable", QuitSuccess)




proc gte_set_control*(reg: uint32, value: uint32) =
    case reg:
        of 0:
            let v0 = cast[int16](value)
            let v1 = cast[int16](value shr 16)
            matrices[ord(Matrix.Rotation)][0][0] = v0
            matrices[ord(Matrix.Rotation)][0][1] = v1
        of 1:
            let v0 = cast[int16](value)
            let v1 = cast[int16](value shr 16)
            matrices[ord(Matrix.Rotation)][0][2] = v0
            matrices[ord(Matrix.Rotation)][1][0] = v1
        of 2:
            let v0 = cast[int16](value)
            let v1 = cast[int16](value shr 16)
            matrices[ord(Matrix.Rotation)][1][1] = v0
            matrices[ord(Matrix.Rotation)][1][2] = v1
        of 3:
            let v0 = cast[int16](value)
            let v1 = cast[int16](value shr 16)
            matrices[ord(Matrix.Rotation)][2][0] = v0
            matrices[ord(Matrix.Rotation)][2][1] = v1
        of 4:
            matrices[ord(Matrix.Rotation)][2][2] = cast[int16](value)
        of 5, 6, 7:
            let index = ord(ControlVector.Translation)
            control_vectors[index][reg - 5] = cast[int32](value)
        of 8:
            let v0 = cast[int16](value)
            let v1 = cast[int16](value shr 16)
            matrices[ord(Matrix.Light)][0][0] = v0
            matrices[ord(Matrix.Light)][0][1] = v1
        of 9:
            let v0 = cast[int16](value)
            let v1 = cast[int16](value shr 16)
            matrices[ord(Matrix.Light)][0][2] = v0
            matrices[ord(Matrix.Light)][1][0] = v1
        of 10:
            let v0 = cast[int16](value)
            let v1 = cast[int16](value shr 16)
            matrices[ord(Matrix.Light)][1][1] = v0
            matrices[ord(Matrix.Light)][1][2] = v1
        of 11:
            let v0 = cast[int16](value)
            let v1 = cast[int16](value shr 16)
            matrices[ord(Matrix.Light)][2][0] = v0
            matrices[ord(Matrix.Light)][2][1] = v1
        of 12:
            matrices[ord(Matrix.Light)][2][2] = cast[int16](value)
        of 13, 14, 15:
            let index = ord(ControlVector.BackgroundColor)
            control_vectors[index][reg - 13] = cast[int32](value)
        of 16:
            let v0 = cast[int16](value)
            let v1 = cast[int16](value shr 16)
            matrices[ord(Matrix.Color)][0][0] = v0
            matrices[ord(Matrix.Color)][0][1] = v1
        of 17:
            let v0 = cast[int16](value)
            let v1 = cast[int16](value shr 16)
            matrices[ord(Matrix.Color)][0][2] = v0
            matrices[ord(Matrix.Color)][1][0] = v1
        of 18:
            let v0 = cast[int16](value)
            let v1 = cast[int16](value shr 16)
            matrices[ord(Matrix.Color)][1][1] = v0
            matrices[ord(Matrix.Color)][1][2] = v1
        of 19:
            let v0 = cast[int16](value)
            let v1 = cast[int16](value shr 16)
            matrices[ord(Matrix.Color)][2][0] = v0
            matrices[ord(Matrix.Color)][2][1] = v1
        of 20:
            matrices[ord(Matrix.Color)][2][2] = cast[int16](value)

        of 21, 22, 23:
            let index = ord(ControlVector.FarColor)
            control_vectors[index][reg - 21] = cast[int32](value)
        of 24: ofx = cast[int32](value)
        of 25: ofy = cast[int32](value)
        of 26: h = cast[uint16](value)
        of 27: dqa = cast[int16](value)
        of 28: dqb = cast[int32](value)
        of 29: zsf3 = cast[int16](value)
        of 30: zsf4 = cast[int16](value)
        of 31:
            flags = value and 0x7FFFF00
            let msb = value and 0x7F87E000
            if msb != 0:
                flags = flags or (1'u32 shl 31)
        else: echo "GTE SET CONTROL ", reg

proc rgbx_to_u32(color: tuple[r: uint8, g: uint8, b: uint8, x: uint8]): uint32 =
    return cast[uint32](color.r) or (cast[uint32](color.g) shl 8) or (cast[uint32](color.b) shl 16) or (cast[uint32](color.x) shl 24)

proc xy_to_u32(xy: tuple[x: int16, y: int16]): uint32 =
    return cast[uint32](cast[uint16](xy.x)) or (cast[uint32](cast[uint16](xy.y)) shl 16)

proc data_saturate(v: int16): uint32 =
    if v < 0:
        return 0'u32
    elif v > 0x1F:
        return 0x1F'u32
    else:
        return cast[uint32](v)

proc gte_data*(reg: uint32): uint32 =
    case reg:
        of 0:
            let v0 = cast[uint32](cast[uint16](v[0][0]))
            let v1 = cast[uint32](cast[uint16](v[0][1]))
            return v0 or (v1 shl 16)
        of 1: return cast[uint32](v[0][2])
        of 2:
            let v0 = cast[uint32](cast[uint16](v[1][0]))
            let v1 = cast[uint32](cast[uint16](v[1][1]))
            return v0 or (v1 shl 16)
        of 3: return cast[uint32](v[1][2])
        of 4:
            let v0 = cast[uint32](cast[uint16](v[2][0]))
            let v1 = cast[uint32](cast[uint16](v[2][1]))
            return v0 or (v1 shl 16)
        of 5: return cast[uint32](v[2][2])
        of 6: return rgbx_to_u32(rgb)
        of 7: return cast[uint32](otz)
        of 8: return cast[uint32](ir[0])
        of 9: return cast[uint32](ir[1])
        of 10: return cast[uint32](ir[2])
        of 11: return cast[uint32](ir[3])
        of 12: return xy_to_u32(xy_fifo[0])
        of 13: xy_to_u32(xy_fifo[1])
        of 14: return xy_to_u32(xy_fifo[2])
        of 15: return xy_to_u32(xy_fifo[3])
        of 16: return cast[uint32](z_fifo[0])
        of 17: return cast[uint32](z_fifo[1])
        of 18: return cast[uint32](z_fifo[2])
        of 19: return cast[uint32](z_fifo[3])
        of 20: return rgbx_to_u32(rgb_fifo[0])
        of 21: return rgbx_to_u32(rgb_fifo[1])
        of 22: return rgbx_to_u32(rgb_fifo[2])
        of 23: return reg_23
        of 24: return cast[uint32](mac[0])
        of 25: return cast[uint32](mac[1])
        of 26: return cast[uint32](mac[2])
        of 27: return cast[uint32](mac[3])
        of 28, 29:
            let a = data_saturate(ir[1] shr 7)
            let b = data_saturate(ir[2] shr 7)
            let c = data_saturate(ir[3] shr 7)
            return a or (b shl 5) or (c shl 10)
        of 30: return lzcs
        of 31: return cast[uint32](lzcr)
        else:
            echo "GTE DATA ", reg
            return 0x00'u32

proc gte_control*(reg: uint32): uint32 =
    case reg:
        of 0:
            let v0 = cast[uint32](cast[uint16](matrices[ord(Matrix.Rotation)][0][0]))
            let v1 = cast[uint32](cast[uint16](matrices[ord(Matrix.Rotation)][0][1]))
            return v0 or (v1 shl 16)
        of 1:
            let v0 = cast[uint32](cast[uint16](matrices[ord(Matrix.Rotation)][0][2]))
            let v1 = cast[uint32](cast[uint16](matrices[ord(Matrix.Rotation)][1][0]))
            return v0 or (v1 shl 16)
        of 2:
            let v0 = cast[uint32](cast[uint16](matrices[ord(Matrix.Rotation)][1][1]))
            let v1 = cast[uint32](cast[uint16](matrices[ord(Matrix.Rotation)][1][2]))
            return v0 or (v1 shl 16)
        of 3:
            let v0 = cast[uint32](cast[uint16](matrices[ord(Matrix.Rotation)][2][0]))
            let v1 = cast[uint32](cast[uint16](matrices[ord(Matrix.Rotation)][2][1]))
            return v0 or (v1 shl 16)
        of 4:
            return cast[uint32](matrices[ord(Matrix.Rotation)][2][2])
        of 5, 6, 7:
            let index = ord(ControlVector.Translation)
            return cast[uint32](control_vectors[index][reg - 5])
        of 8:
            let v0 = cast[uint32](cast[uint16](matrices[ord(Matrix.Light)][0][0]))
            let v1 = cast[uint32](cast[uint16](matrices[ord(Matrix.Light)][0][1]))
            return v0 or (v1 shl 16)
        of 9:
            let v0 = cast[uint32](cast[uint16](matrices[ord(Matrix.Light)][0][2]))
            let v1 = cast[uint32](cast[uint16](matrices[ord(Matrix.Light)][1][0]))
            return v0 or (v1 shl 16)
        of 10:
            let v0 = cast[uint32](cast[uint16](matrices[ord(Matrix.Light)][1][1]))
            let v1 = cast[uint32](cast[uint16](matrices[ord(Matrix.Light)][1][2]))
            return v0 or (v1 shl 16)
        of 11:
            let v0 = cast[uint32](cast[uint16](matrices[ord(Matrix.Light)][2][0]))
            let v1 = cast[uint32](cast[uint16](matrices[ord(Matrix.Light)][2][1]))
            return v0 or (v1 shl 16)
        of 12:
            return cast[uint32](matrices[ord(Matrix.Light)][2][2])
        of 13, 14, 15:
            let index = ord(ControlVector.BackgroundColor)
            return cast[uint32](control_vectors[index][reg - 13])
        of 16:
            let v0 = cast[uint32](cast[uint16](matrices[ord(Matrix.Color)][0][0]))
            let v1 = cast[uint32](cast[uint16](matrices[ord(Matrix.Color)][0][1]))
            return v0 or (v1 shl 16)
        of 17:
            let v0 = cast[uint32](cast[uint16](matrices[ord(Matrix.Color)][0][2]))
            let v1 = cast[uint32](cast[uint16](matrices[ord(Matrix.Color)][1][0]))
            return v0 or (v1 shl 16)
        of 18:
            let v0 = cast[uint32](cast[uint16](matrices[ord(Matrix.Color)][1][1]))
            let v1 = cast[uint32](cast[uint16](matrices[ord(Matrix.Color)][1][2]))
            return v0 or (v1 shl 16)
        of 19:
            let v0 = cast[uint32](cast[uint16](matrices[ord(Matrix.Color)][2][0]))
            let v1 = cast[uint32](cast[uint16](matrices[ord(Matrix.Color)][2][1]))
            return v0 or (v1 shl 16)
        of 20:
            return cast[uint32](matrices[ord(Matrix.Color)][2][2])
        of 21, 22, 23:
            let index = ord(ControlVector.FarColor)
            return cast[uint32](control_vectors[index][reg - 21])
        of 24: return cast[uint32](ofx)
        of 25: return cast[uint32](ofy)
        of 26: return cast[uint32](cast[int16](h))
        of 27: return cast[uint32](dqa)
        of 28: return cast[uint32](dqb)
        of 29: return cast[uint32](zsf3)
        of 30: return cast[uint32](zsf4)
        of 31: return flags
        else:
            echo "GTE CONTROL ", reg
            return 0x00'u32





# Tests and stuff I guess
proc reset_gte(test: Test, set_regs: bool) =
    ofx = 0'i32 # Screen offset X
    ofy = 0'i32 # Screen offset Y
    h = 0'u16 # Projection plane distance
    dqa = 0'i16 # Depth queing coeffient
    dqb = 0'i32 # Depth queing offset
    zsf3 = 0'i16 # Scale factor for average of 3 Z values
    zsf4 = 0'i16 # Scale factor for average of 4 Z values
    matrices = [
        [[0'i16, 0'i16, 0'i16], [0'i16, 0'i16, 0'i16], [0'i16, 0'i16, 0'i16]],
        [[0'i16, 0'i16, 0'i16], [0'i16, 0'i16, 0'i16], [0'i16, 0'i16, 0'i16]],
        [[0'i16, 0'i16, 0'i16], [0'i16, 0'i16, 0'i16], [0'i16, 0'i16, 0'i16]],
    ]  # Three 3x3 signed matrices
    control_vectors = [[0'i32, 0'i32, 0'i32], [0'i32, 0'i32, 0'i32], [0'i32, 0'i32, 0'i32], [0'i32, 0'i32, 0'i32]] # Five 3x signed words control vectors
    flags = 0'u32 # Overflow flags

    # Data
    v = [[0'i16, 0'i16, 0'i16], [0'i16, 0'i16, 0'i16], [0'i16, 0'i16, 0'i16], [0'i16, 0'i16, 0'i16]] # Vectors 3x3 signed
    mac = [0'i32, 0'i32, 0'i32, 0'i32] # Accumulators
    otz = 0'u16 # Z average
    rgb = (0'u8, 0'u8, 0'u8, 0'u8) # RGB color
    ir = [0'i16, 0'i16, 0'i16, 0'i16] # Accumulators
    xy_fifo = [(0'i16, 0'i16), (0'i16, 0'i16), (0'i16, 0'i16), (0'i16, 0'i16)]
    z_fifo = [0'u16, 0'u16, 0'u16, 0'u16]
    rgb_fifo = [(0'u8, 0'u8, 0'u8, 0'u8), (0'u8, 0'u8, 0'u8, 0'u8), (0'u8, 0'u8, 0'u8, 0'u8)]
    lzcs = 0'u32 # Input value
    lzcr = 32'u8 # Numbers for leading zeroes in lzsc
    reg_23 = 0'u32

    if set_regs:
        for (reg, val) in test.reset_controls:
            gte_set_control(cast[uint32](reg), val)

        for (reg, val) in test.reset_data:
            if reg == 15:
                discard
            elif reg == 28:
                discard
            elif reg == 29:
                discard
            else:
                gte_set_data(cast[uint32](reg), val)

proc validate_result(test: Test) =
    var errors = 0'u32
    for (reg, val) in test.result_controls:
        let v = gte_control(uint32(reg))
        if v != val:
            echo "Control register ", reg, " expected 0x", val.toHex(), " got 0x", v.toHex()
            errors += 1

    for (reg, val) in test.result_data:
        let v = gte_data(uint32(reg))
        if v != val:
            echo "Data register ", reg, " expected 0x", val.toHex(), " got 0x", v.toHex()
            errors += 1

    if errors > 0:
        echo "Got ", errors, " errors :("
        quit("", QuitSuccess)

proc gte_ops_test*() =
    echo ""
    echo "Running GTE tests"
    for test in TESTS:
        echo "Test: ", test.desc
        echo "Command: 0x", test.command.toHex()
        reset_gte(test, true)
        gte_command(test.command)
        validate_result(test)

    reset_gte(TESTS[0], false)

    assert divide(0, 1) == 0
    assert divide(0, 1234) == 0
    assert divide(1, 1) == 0x10000
    assert divide(2, 2) == 0x10000
    assert divide(0xFFFF, 0xFFFF) == 0xFFFF
    assert divide(0xFFFF, 0xFFFE) == 0x10000
    assert divide(1, 2) == 0x8000
    assert divide(1, 3) == 0x5555
    assert divide(5, 6) == 0xd555

    assert divide(1, 4) == 0x4000
    assert divide(10, 40) == 0x4000
    assert divide(0xF00, 0xbeef) == 0x141d
    assert divide(9876, 8765) == 0x12072
    assert divide(200, 10000) == 0x51f
    assert divide(0xFFFF, 0x8000) == 0x1FFFE
    assert divide(0xE5D7, 0x72EC) == 0x1FFFF

    for i in 0 ..< 0x100'u32:
        let v = (0x40000 div (i + 0x100) + 1) div 2 - 0x101
        assert cast[uint32](UNR_TABLE[i]) == v
    assert UNR_TABLE[0xFF] == UNR_TABLE[0x100]

    echo "All tests passed!"




#
