MEMORY {
    /* Pico 2 has 4 MiB flash */
    FLASH : ORIGIN = 0x10000000, LENGTH = 4096K

    /* RP2350 SRAM: 512 KiB striped across banks 0-7 */
    RAM   : ORIGIN = 0x20000000, LENGTH = 512K

    /* Direct-mapped SRAM banks for per-core stacks */
    SRAM8 : ORIGIN = 0x20080000, LENGTH = 4K
    SRAM9 : ORIGIN = 0x20081000, LENGTH = 4K
}

SECTIONS {
    /* Boot information block */
    .start_block : ALIGN(4) {
        KEEP(*(.start_block));
    } > FLASH

    /* Binary info entries for picotool */
    .bi_entries : ALIGN(4) {
        __bi_entries_start = .;
        KEEP(*(.bi_entries));
        __bi_entries_end = .;
    } > FLASH

    /* End block for boot signatures */
    .end_block : ALIGN(4) {
        KEEP(*(.end_block));
    } > FLASH
}

/* Position executable code after boot info */
_stext = ADDR(.start_block) + SIZEOF(.start_block);
