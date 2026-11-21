/* CoreCascade v2 memory layout
 *   ITCM   code + constants (CPU fetch port; constants read through the crossbar)
 *   DTCM   CPU-private variables and stack
 *   SHARED GPU kernels, command ring, GPU data windows, framebuffers
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    ITCM   (rx) : ORIGIN = 0x00000000, LENGTH = 32K
    DTCM   (rw) : ORIGIN = 0x10000000, LENGTH = 16K
    SHARED (rw) : ORIGIN = 0x20000000, LENGTH = 256K
}

SECTIONS
{
    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
    } > ITCM

    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > ITCM

    .data : { *(.data .data.* .sdata .sdata.*) } > DTCM

    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > DTCM

    __stack_top = ORIGIN(DTCM) + LENGTH(DTCM);

    /* GPU kernel binaries: loaded with the program, fetched by the command processor */
    .gpu : { . = ALIGN(4); KEEP(*(.gpu .gpu.*)) } > SHARED

    /* buffers shared with the GPU and the display (not loaded) */
    .shared (NOLOAD) : { . = ALIGN(32); *(.shared .shared.*) } > SHARED

    /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.eh_frame*) }
}
