# Reset entry: stack at the top of DTCM, clear .bss, run main, report exit code.
    .section .text.start
    .globl _start
_start:
    la   sp, __stack_top
    la   t0, __bss_start
    la   t1, __bss_end
1:  bgeu t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b
2:  call main
    li   t0, 0x40000004          # SYS_EXIT
    sw   a0, 0(t0)
3:  j    3b
