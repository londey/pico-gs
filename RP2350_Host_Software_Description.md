# RP2350 Host Software Description

I would like to add a specification for the host software to run on a PICO 2 RP2350 that will drive the spi-gpu via the SPI + GPIO interface.
- The software will be written in Rust
- I feel the software should target the Cortex M33 cores due to the hardware FPU and DSP extensions
- Core 0 will run the main thread and be responsible for:
  - Managing the scene graph
  - Connecting to a USB keyboard for controlling the software
    - Number keys should switch between different demos. Initially:
      - Goroud shaded triangle
      - Textured triangle
      - spinning Utah Teapot
  - Generating render commands for a command queue to be executed by core 1
- Core 1 will be responsible for executing render commands and managing to connection to the spi-gpu
  - Render commands will include the following
    - Render mesh patch which will be a small patch of <128 vertices + indices from which the software will apply a transform matrix and lighting calculations for 4 directional lights + ambient before using the indices to push the triangles to the spi-gpu as triangle strips with strip restart which will require a gpu register change to have separate registers for push triangle strip vertex with no draw, and push triangle strip vertex with draw
    - Upload texture data to spi-gpu texture memory
    - Wait for vertical sync (via GPIO from spi-gpu)
    - Clear framebuffer with a specified color using a triangle that covers the entire screen
  - Core 1 should use DMA to asynchonusly transfer data from flash before processing it for rendering
  - I would like Core 1 to use DMA to asynchronously push prepared SPI commands to the spi-gpu to minimize CPU load however will need to work out if this is possible with the spi-gpu register write FIFO full push back