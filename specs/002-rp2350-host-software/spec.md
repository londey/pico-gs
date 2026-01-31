# Feature Specification: RP2350 Host Software

**Feature Branch**: `002-rp2350-host-software`
**Created**: 2026-01-30
**Status**: Draft
**Input**: User description: "Add specification for the host software to run on an RP2350 and connect to the SPI GPU via SPI and GPIO. I have placed some initial thoughts in RP2350_Host_Software_Description.md"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Flat-Shaded Triangle Rendering (Priority: P1)

As a developer, I can build and deploy the host software to the RP2350, and upon startup it renders a single Gouraud-shaded triangle on the display using the connected SPI GPU. This validates the entire end-to-end pipeline: host initialization, SPI communication, GPU command submission, and display output.

**Why this priority**: This is the minimum viable demonstration that the host software can communicate with the GPU and produce visible output. Every other feature depends on this foundation.

**Independent Test**: Can be fully tested by deploying the firmware, powering on the system, and visually confirming a shaded triangle appears on the display at a stable frame rate.

**Acceptance Scenarios**:

1. **Given** the host software is deployed and powered on, **When** the system completes initialization, **Then** a Gouraud-shaded triangle is rendered on the display within 2 seconds of boot.
2. **Given** the shaded triangle demo is running, **When** the display is observed over 60 seconds, **Then** the output remains stable with no visible tearing or corruption.
3. **Given** the shaded triangle demo is running, **When** the frame rate is measured, **Then** it maintains at least 30 frames per second.

---

### User Story 2 - Textured Triangle Rendering (Priority: P2)

As a developer, I can switch to a textured triangle demo that uploads texture data to the GPU and renders a triangle with that texture applied. This validates the texture upload pipeline and texture-mapped rendering.

**Why this priority**: Texture support is essential for realistic 3D rendering and validates the memory upload interface to the GPU.

**Independent Test**: Can be tested by selecting the textured triangle demo and confirming the triangle displays with the correct texture, with no visual artifacts.

**Acceptance Scenarios**:

1. **Given** the system is running, **When** the textured triangle demo is selected, **Then** texture data is uploaded to the GPU and a textured triangle is displayed within 1 second.
2. **Given** the textured triangle demo is active, **When** the rendered output is inspected, **Then** the texture is correctly mapped with no visible distortion or seams.
3. **Given** the textured triangle demo is active, **When** the frame rate is measured, **Then** it maintains at least 30 frames per second.

---

### User Story 3 - Spinning Utah Teapot (Priority: P3)

As a developer, I can switch to a spinning Utah Teapot demo that demonstrates the full 3D rendering pipeline: mesh management, geometric transformation, lighting calculations, depth testing, and continuous animation. This validates the mesh rendering command, transform pipeline, and multi-light shading.

**Why this priority**: The teapot demo is the target showcase, proving the system can handle real 3D workloads with transformation, lighting, and depth-sorted rendering.

**Independent Test**: Can be tested by selecting the teapot demo and confirming a lit, rotating teapot is rendered smoothly with correct depth ordering.

**Acceptance Scenarios**:

1. **Given** the system is running, **When** the Utah Teapot demo is selected, **Then** a lit, rotating teapot is displayed with correct depth ordering within 2 seconds.
2. **Given** the teapot demo is active, **When** the rendered output is observed, **Then** the teapot is illuminated by multiple directional lights plus ambient light with smooth Gouraud shading across faces.
3. **Given** the teapot demo is active, **When** the frame rate is measured, **Then** it maintains at least 30 frames per second.
4. **Given** the teapot demo is active, **When** the teapot rotates through a full revolution, **Then** back-face culling and depth testing produce correct visual results with no z-fighting or inverted faces.

---

### User Story 4 - USB Keyboard Demo Switching (Priority: P4)

As a user, I can connect a USB keyboard and press number keys to switch between available demos in real time. This provides interactive control over which demonstration is displayed.

**Why this priority**: Interactive control is needed for demonstration purposes but is not required for validating the rendering pipeline itself.

**Independent Test**: Can be tested by connecting a USB keyboard, pressing number keys 1-3, and confirming the display switches to the corresponding demo.

**Acceptance Scenarios**:

1. **Given** the system is running any demo, **When** a USB keyboard is connected, **Then** the system recognizes the keyboard and accepts input.
2. **Given** a keyboard is connected and a demo is running, **When** the user presses key "1", **Then** the display switches to the Gouraud-shaded triangle demo.
3. **Given** a keyboard is connected and a demo is running, **When** the user presses key "2", **Then** the display switches to the textured triangle demo.
4. **Given** a keyboard is connected and a demo is running, **When** the user presses key "3", **Then** the display switches to the spinning Utah Teapot demo.
5. **Given** a demo switch is triggered, **When** the transition occurs, **Then** the new demo begins rendering within 1 second with no system hang or crash.

---

### User Story 5 - Dual-Core Render Pipeline (Priority: P5)

As a developer, the host software partitions work across two processing cores: one core manages the scene graph, user input, and render command generation, while the second core executes render commands and manages GPU communication. This ensures the rendering pipeline does not block input handling or scene updates.

**Why this priority**: Dual-core partitioning is an architectural enabler for meeting frame rate targets, but can be validated only after the basic rendering pipeline is working.

**Independent Test**: Can be tested by running any demo and measuring that input responsiveness remains consistent regardless of rendering load, and that the render core utilization stays within acceptable bounds.

**Acceptance Scenarios**:

1. **Given** the teapot demo is running at full load, **When** a demo switch key is pressed, **Then** the system responds within 500 milliseconds.
2. **Given** any demo is running, **When** the processing core utilization is measured, **Then** neither core exceeds 80% sustained utilization.
3. **Given** both cores are active, **When** the render command queue is monitored, **Then** commands flow from the scene core to the render core without drops or stalls under normal operating conditions.

---

### User Story 6 - Asynchronous GPU Communication (Priority: P6)

As a developer, the render core transfers prepared data to the GPU asynchronously, allowing the processor to prepare the next batch of commands while the current batch is being transmitted. The system respects the GPU's flow control signals to avoid dropped commands.

**Why this priority**: Asynchronous transfers are a performance optimization that maximizes throughput, but the system must work correctly with synchronous transfers first.

**Independent Test**: Can be tested by running the teapot demo and comparing render core idle time with and without asynchronous transfers enabled.

**Acceptance Scenarios**:

1. **Given** the teapot demo is running with asynchronous transfers, **When** the render core activity is profiled, **Then** the core spends less than 50% of its time waiting for data transfers to complete.
2. **Given** the GPU's command buffer is nearly full, **When** the host attempts to send more commands, **Then** the host pauses transmission until the GPU signals buffer space is available, and no commands are dropped.
3. **Given** asynchronous data loading from storage is in progress, **When** the render core needs to process the data, **Then** the core does not stall waiting for the load to complete and instead processes other available work.

---

### Edge Cases

- What happens when the GPU command buffer is full and the host has pending commands? The host must pause and wait for the buffer-space-available signal before continuing.
- What happens when the user presses an invalid key (not 1-3)? The system ignores the input and continues running the current demo.
- What happens when no USB keyboard is connected? The system starts the default demo (Gouraud-shaded triangle) and operates normally without keyboard input.
- What happens when a demo switch is requested during a frame render? The current frame completes, then the new demo begins on the next frame boundary.
- What happens when the mesh data for a patch exceeds the maximum vertex count? The mesh is split into multiple patches that each fit within the vertex limit.
- What happens when a texture is too large for the available GPU texture memory? The system reports an error during texture upload and falls back to untextured rendering.
- What happens when the render command queue is full and Core 0 attempts to enqueue a new command? Core 0 blocks until queue space becomes available (backpressure). No commands are dropped.
- What happens when the GPU is not detected on startup (absent, wrong device ID, or SPI bus fault)? The system halts and signals the failure visibly (e.g., LED blink pattern) to aid debugging.
- What happens if SPI communication errors occur during rendering (corrupted transaction, bus glitch)? The system does not perform runtime SPI error detection. The SPI bus is trusted for correctness. If visual corruption occurs, a power cycle resolves it.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST initialize communication with the SPI GPU and verify the GPU is present by reading its device identifier on startup. If the GPU is not detected or returns an unexpected identifier, the system MUST halt and signal the failure visibly to the user.
- **FR-002**: The system MUST partition processing across two cores: one core for scene management and user input, and one core for render command execution and GPU communication.
- **FR-003**: The scene management core MUST maintain a scene graph representing the current demo's 3D objects, including mesh geometry, transformation state, and material properties.
- **FR-004**: The scene management core MUST accept USB keyboard input and map number keys 1-3 to demo selection (1: Gouraud-shaded triangle, 2: Textured triangle, 3: Spinning Utah Teapot).
- **FR-005**: The scene management core MUST generate render commands and place them in an inter-core command queue for execution by the render core.
- **FR-006**: The render command queue MUST support at least the following command types: render mesh patch, upload texture, wait for vertical sync, and clear framebuffer.
- **FR-006a**: The render command queue MUST apply backpressure when full: the scene management core blocks until queue space becomes available. No commands are dropped.
- **FR-007**: The render mesh patch command MUST accept a batch of up to 128 vertices and associated index data, apply a transformation matrix to convert object-space vertices to screen-space, and calculate lighting for up to 4 directional lights plus ambient light.
- **FR-008**: The render mesh patch command MUST submit transformed, lit triangles to the GPU as triangle strips with strip restart capability, requiring the GPU to support separate vertex submission modes for "advance strip without drawing" and "advance strip and draw".
- **FR-009**: The upload texture command MUST transfer texture image data to the GPU's texture memory region using the GPU's memory upload interface.
- **FR-010**: The wait for vertical sync command MUST block the render core until the GPU asserts the vertical sync signal via its dedicated GPIO line.
- **FR-011**: The clear framebuffer command MUST clear the display to a specified color by rendering a full-screen triangle that covers the entire viewport.
- **FR-012**: The render core MUST respect the GPU's flow control signal indicating the command buffer is nearly full, pausing command submission until space is available.
- **FR-013**: The render core MUST support asynchronous data loading from storage so that mesh and texture data can be pre-fetched while other processing continues.
- **FR-014**: The render core SHOULD support asynchronous transmission of prepared GPU commands to minimize processor idle time during SPI data transfer. This is a stretch goal contingent on resolving the interaction between asynchronous SPI transfers and the GPU's FIFO-full flow control signal.
- **FR-015**: The system MUST start the default demo (Gouraud-shaded triangle) automatically on power-on without requiring any user input.
- **FR-016**: The system MUST maintain double-buffered rendering, presenting completed frames only on vertical sync boundaries to prevent visual tearing.

### Key Entities

- **Scene Graph**: A hierarchical representation of 3D objects in the current demo, containing meshes, transformations, and material properties. Updated by the scene management core each frame.
- **Render Command**: A unit of work placed in the inter-core queue by the scene management core and consumed by the render core. Types: render mesh patch, upload texture, wait for vertical sync, clear framebuffer.
- **Mesh Patch**: A batch of up to 128 vertices with associated index data representing a portion of a 3D model. Includes vertex positions, normals, colors, and texture coordinates.
- **Transformation Matrix**: A 4x4 matrix applied to mesh patch vertices to convert from object space to screen space, incorporating model, view, and projection transforms.
- **Light Source**: A directional light with direction vector and color/intensity. The system supports up to 4 directional lights plus one ambient light level.
- **Texture**: A rectangular image to be uploaded to GPU memory and mapped onto triangle surfaces during rendering.
- **Demo**: A predefined rendering scenario with associated scene graph, meshes, textures, and animation logic. Three initial demos: Gouraud-shaded triangle, textured triangle, spinning Utah Teapot.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All three demos (Gouraud-shaded triangle, textured triangle, spinning Utah Teapot) render at 30 frames per second or higher.
- **SC-002**: Demo switching via keyboard input completes within 1 second of the key press, with no visual corruption during the transition.
- **SC-003**: The spinning Utah Teapot demo displays correct Gouraud shading from 4 directional lights plus ambient, with no visible banding or lighting artifacts.
- **SC-004**: The display output remains stable at 60 Hz with no visible tearing across all demos when observed over a 5-minute period.
- **SC-005**: Neither processing core exceeds 80% sustained utilization during the most demanding demo (Utah Teapot).
- **SC-006**: The render core spends less than 50% of its time waiting for GPU data transfers when asynchronous transfers are enabled.
- **SC-007**: The system starts and displays the default demo within 2 seconds of power-on.
- **SC-008**: The system operates correctly with or without a USB keyboard connected.

## Clarifications

### Session 2026-01-30

- Q: When the render command queue is full and Core 0 tries to enqueue, should it block (backpressure), drop oldest commands, or skip the frame? → A: Block (backpressure) — Core 0 waits until queue space is available. No commands are dropped.
- Q: If the GPU is not detected on startup, should the system retry indefinitely, halt with error indicator, or retry with timeout? → A: Halt with visible error indicator (e.g., LED blink pattern) to aid hardware debugging.
- Q: Should the system detect and recover from SPI communication errors during rendering? → A: No runtime SPI error detection. The bus is trusted; power cycle resolves any corruption.

## Assumptions

- The SPI GPU hardware is available and functioning per the SPI GPU v2.0 specification, including the register map, SPI protocol, and memory map contracts.
- The GPU supports the required triangle strip vertex submission modes (advance without draw and advance with draw). If not present in the current GPU spec, this is flagged as a dependency requiring a GPU specification update.
- The GPU provides CMD_FULL, CMD_EMPTY, and VSYNC GPIO signals as defined in the SPI protocol specification.
- The RP2350 has sufficient flash storage to hold all demo mesh data (Utah Teapot geometry), texture data, and firmware.
- USB HID keyboard support is available through the target platform's standard peripheral interfaces.
- The 3D transformation and lighting calculations (matrix multiply, dot products) are performed using the RP2350's hardware floating-point unit for adequate throughput.
- The inter-core command queue uses a lock-free mechanism to avoid contention between the two cores.
- Texture dimensions for the demos are power-of-two and fit within the GPU's texture memory allocation (approximately 768 KB).
- The SPI bus operates reliably without runtime error detection. The short physical connection between the RP2350 and GPU makes bus errors negligible for a demo system.

## Dependencies

- **SPI GPU v2.0 Specification**: The host software depends on the GPU implementing the register map, SPI protocol, and memory map as specified. Any changes to these contracts require corresponding host software updates.
- **Triangle Strip Registers**: FR-008 requires the GPU to support separate "push vertex without draw" and "push vertex with draw" registers for triangle strip rendering with strip restart. This may require an update to the GPU register map specification.
- **GPIO Signals**: The host relies on CMD_FULL and VSYNC GPIO signals for flow control and frame synchronization.
