// PLL Core - Clock Generation for ICEpi GPU
// Input: 50 MHz from board oscillator
// Outputs: 100 MHz (SRAM), 25.175 MHz (pixel), 251.75 MHz (TMDS)

module pll_core (
    input  wire clk_50_in,      // 50 MHz input clock
    input  wire rst_n,          // Active-low reset

    output wire clk_100,        // 100 MHz for SRAM controller
    output wire clk_pixel,      // 25.175 MHz for display timing
    output wire clk_tmds,       // 251.75 MHz for TMDS serializer
    output wire pll_locked      // PLL lock indicator
);

    // ECP5 EHXPLLL primitive instantiation
    // The ECP5 PLL can generate multiple output clocks from a single input
    // We'll use the following configuration:
    //   - CLKOP: 100 MHz (primary output, divide by 1, multiply to get 100 from 50)
    //   - CLKOS: 25.175 MHz (secondary output)
    //   - CLKOS2: 251.75 MHz (tertiary output, 10x pixel clock for SERDES)

    wire clkop_w;   // 100 MHz
    wire clkos_w;   // 25.175 MHz
    wire clkos2_w;  // 251.75 MHz
    wire lock_w;

    // ECP5 PLL primitive
    // CLKI_DIV = 1, CLKFB_DIV = 1, CLKOP_DIV = 6 gives us flexibility
    // Reference frequency: 50 MHz
    // VCO frequency: should be in range 400-800 MHz
    // For 25.175 MHz: VCO = 503.5 MHz (25.175 * 20)
    // CLKOP = 503.5 / 5.035 ≈ 100 MHz
    // CLKOS = 503.5 / 20 = 25.175 MHz
    // CLKOS2 = 503.5 / 2 = 251.75 MHz

    EHXPLLL #(
        .CLKI_DIV(1),           // Input divider
        .CLKFB_DIV(1),          // Feedback divider
        .FEEDBK_PATH("CLKOP"),  // Feedback from CLKOP

        // VCO = 50 MHz * CLKOP_DIV * (CLKFB_DIV / CLKI_DIV) = need ~504 MHz
        .CLKOP_DIV(5),          // Primary output: 504/5 ≈ 100.8 MHz (close to 100)
        .CLKOP_ENABLE("ENABLED"),
        .CLKOP_CPHASE(0),
        .CLKOP_FPHASE(0),

        .CLKOS_DIV(20),         // Secondary output: 504/20 = 25.2 MHz (close to 25.175)
        .CLKOS_ENABLE("ENABLED"),
        .CLKOS_CPHASE(0),
        .CLKOS_FPHASE(0),

        .CLKOS2_DIV(2),         // Tertiary output: 504/2 = 252 MHz (close to 251.75)
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
    assign clk_100 = clkop_w;
    assign clk_pixel = clkos_w;
    assign clk_tmds = clkos2_w;
    assign pll_locked = lock_w;

endmodule
