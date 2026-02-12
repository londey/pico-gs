MEMORY {
    /* Pico 2 has 4 MiB flash.
     * BOOT_INFO holds RP2350 block loop structures (IMAGE_DEF, binary info)
     * that the boot ROM scans within the first 4 KiB.
     * FLASH starts after BOOT_INFO for the vector table and code. */
    BOOT_INFO : ORIGIN = 0x10000000, LENGTH = 0x100
    FLASH     : ORIGIN = 0x10000100, LENGTH = 4096K - 0x100

    /* RP2350 SRAM: 512 KiB striped across banks 0-7 */
    RAM : ORIGIN = 0x20000000, LENGTH = 512K

    /* Direct-mapped SRAM banks for per-core stacks.
     * Core 0 stack: SRAM8, Core 1 stack: SRAM9.
     * MPU guard regions at the bottom 32 bytes of each bank
     * catch overflow with a MemManage fault. */
    SRAM8 : ORIGIN = 0x20080000, LENGTH = 4K
    SRAM9 : ORIGIN = 0x20081000, LENGTH = 4K
}

SECTIONS {
    /* RP2350 boot block structures (scanned by boot ROM) */
    .start_block : ALIGN(4) {
        KEEP(*(.start_block));
    } > BOOT_INFO

    .bi_entries : ALIGN(4) {
        __bi_entries_start = .;
        KEEP(*(.bi_entries));
        __bi_entries_end = .;
    } > BOOT_INFO

    .end_block : ALIGN(4) {
        KEEP(*(.end_block));
    } > BOOT_INFO

    /* Core 1 stack buffer placed in dedicated SRAM9 bank */
    .core1_stack (NOLOAD) : ALIGN(32) {
        *(.core1_stack .core1_stack.*);
    } > SRAM9
}

/* Core 0 initial stack pointer: top of SRAM8 (stack grows downward) */
_stack_start = ORIGIN(SRAM8) + LENGTH(SRAM8);
