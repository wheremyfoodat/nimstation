import strutils
type
    Interrupt* = enum
        VBlank = 0
        CdRom = 2
        Dma = 3
        Timer0 = 4
        Timer1 = 5
        Timer2 = 6
        PadMemCard = 7

    pending_irq = tuple
        delay: uint16
        irq: Interrupt

var status: uint16
var mask: uint16
var pending_irqs: seq[pending_irq]

proc get_irq_status*(): uint16 =
    return status

proc get_irq_mask*(): uint16 =
    return mask

proc irq_ack*(value: uint16) =
    status = status and value

proc irq_set_mask*(value: uint16) =
    echo "Set IRQ mask to ", int64(value).toBin(16)
    mask = value

proc irq_active*(): bool =
    return (status and mask) != 0

proc pend_irq*(delay: uint16, which: Interrupt) =
    echo "Got new interrupt pending ", which
    pending_irqs.add((delay, which))

proc assert_irq*(which: Interrupt) =
    status = status or (1'u16 shl uint16(ord(which)))

proc irq_tick*() =
    if pending_irqs.len != 0:
        var to_delete: seq[int]
        for i in (0 ..< pending_irqs.len):
            var interrupt = pending_irqs[i]
            var delay = interrupt[0]
            delay -= 1
            if delay == 0:
                assert_irq(pending_irqs[i][1])
                to_delete.add(i)
            else:
                pending_irqs[i] = (delay, interrupt[1])

        if to_delete.len != 0:
            for i in (0 ..< to_delete.len):
                pending_irqs.delete(to_delete.pop())
