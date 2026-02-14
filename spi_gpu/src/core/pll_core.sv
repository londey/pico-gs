// PLL Core - Clock Generation for ICEpi GPU
// Input: 50 MHz from board oscillator
// Outputs: 100 MHz unified GPU/SRAM core clock (clk_core),
//          25.000 MHz pixel clock (clk_core / 4, synchronous),
//          250.0 MHz TMDS bit clock (10x pixel clock)

module pll_core (
    input  wire clk_50_in,      // 50 MHz input clock
    input  wire rst_n,          // Active-low reset

    output wire clk_core,       // 100 MHz unified GPU core/SRAM clock
    output wire clk_pixel,      // 25.000 MHz pixel clock (clk_core / 4)
    output wire clk_tmds,       // 250.0 MHz TMDS bit clock (10x pixel clock)
    output wire pll_locked      // PLL lock indicator
);

    // ECP5 EHXPLLL primitive instantiation
    // Generates three synchronous clocks from 50 MHz board oscillator:
    //   - CLKOP:  100.0 MHz (clk_core — unified GPU core/SRAM clock)
    //   - CLKOS:   25.0 MHz (clk_pixel — clk_core / 4, synchronous)
    //   - CLKOS2: 250.0 MHz (clk_tmds — 10x pixel clock for TMDS serializer)

    wire clkop_w;   // 100 MHz (clk_core)
    wire clkos_w;   // 25.000 MHz (clk_pixel)
    wire clkos2_w;  // 250.0 MHz (clk_tmds)
    wire lock_w;

    // ECP5 PLL with FEEDBK_PATH="CLKOP":
    //   VCO = (CLKI / CLKI_DIV) * CLKFB_DIV * CLKOP_DIV  (per TN1263)
    //       = (50 / 1) * 2 * 5 = 500 MHz (within 400-800 MHz range)
    //   CLKOP  = VCO / CLKOP_DIV  = 500 / 5  = 100.0 MHz (clk_core)
    //   CLKOS  = VCO / CLKOS_DIV  = 500 / 20 =  25.0 MHz (clk_pixel = clk_core / 4)
    //   CLKOS2 = VCO / CLKOS2_DIV = 500 / 2  = 250.0 MHz (clk_tmds = 10x pixel)

    EHXPLLL #(
        .CLKI_DIV(1),           // Input divider
        .CLKFB_DIV(2),          // Feedback divider (VCO = 50 * 2 * 5 = 500 MHz)
        .FEEDBK_PATH("CLKOP"),  // Feedback from CLKOP

        .CLKOP_DIV(5),          // Primary output: 500/5 = 100 MHz (clk_core)
        .CLKOP_ENABLE("ENABLED"),
        .CLKOP_CPHASE(0),
        .CLKOP_FPHASE(0),

        .CLKOS_DIV(20),         // Secondary output: 500/20 = 25.0 MHz (clk_pixel)
        .CLKOS_ENABLE("ENABLED"),
        .CLKOS_CPHASE(0),
        .CLKOS_FPHASE(0),

        .CLKOS2_DIV(2),         // Tertiary output: 500/2 = 250.0 MHz (clk_tmds)
        .CLKOS2_ENABLE("ENABLED"),
        .CLKOS2_CPHASE(0),
        .CLKOS2_FPHASE(0),

        .CLKOS3_DIV(1),
        .CLKOS3_ENABLE("DISABLED"),

        .CLKOP_TRIM_POL("FALLING"),
        .CLKOP_TRIM_DELAY(0),
        .CLKOS_TRIM_POL("FALLING"),
        .CLKOS_TRIM_DELAY(0),

        .OUTDIVIDER_MUXA("DIVA"),
        .OUTDIVIDER_MUXB("DIVB"),
        .OUTDIVIDER_MUXC("DIVC"),
        .OUTDIVIDER_MUXD("DIVD"),

        .PLL_LOCK_MODE(0),
        .PLL_LOCK_DELAY(200),
        .STDBY_ENABLE("DISABLED"),
        .REFIN_RESET("DISABLED"),
        .SYNC_ENABLE("DISABLED"),
        .INT_LOCK_STICKY("ENABLED"),
        .DPHASE_SOURCE("DISABLED"),
        .PLLRST_ENA("DISABLED"),
        .INTFB_WAKE("DISABLED")
    ) pll_inst (
        .CLKI(clk_50_in),
        .CLKFB(clkop_w),
        .RST(1'b0),
        .STDBY(1'b0),
        .PHASESEL0(1'b0),
        .PHASESEL1(1'b0),
        .PHASEDIR(1'b0),
        .PHASESTEP(1'b0),
        .PHASELOADREG(1'b0),

        .CLKOP(clkop_w),
        .CLKOS(clkos_w),
        .CLKOS2(clkos2_w),
        .CLKOS3(),
        .LOCK(lock_w),
        .INTLOCK(),
        .CLKINTFB()
    );

    // Output assignments
    assign clk_core = clkop_w;
    assign clk_pixel = clkos_w;
    assign clk_tmds = clkos2_w;
    assign pll_locked = lock_w;

endmodule
