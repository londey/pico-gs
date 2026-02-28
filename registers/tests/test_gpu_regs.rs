use gpu_registers::components::gpu_regs;

/// Test all generated component addresses against the SystemRDL assigned address
#[test]
fn test_gpu_regs_addresses() {
    const SIZE: usize = gpu_regs::GpuRegs::SIZE;
    let mut memory = [0u8; SIZE];
    let base_addr = memory.as_mut_ptr();
    let dut = unsafe { gpu_regs::GpuRegs::from_ptr(base_addr as _) };

    assert_eq!(dut.as_ptr() as *mut u8, base_addr);
    assert_eq!(
        dut.color().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0x0)
    );
    assert_eq!(
        dut.uv0_uv1().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0x8)
    );
    assert_eq!(
        dut.area_setup().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0x28)
    );
    assert_eq!(
        dut.vertex_nokick().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0x30)
    );
    assert_eq!(
        dut.vertex_kick_012().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0x38)
    );
    assert_eq!(
        dut.vertex_kick_021().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0x40)
    );
    assert_eq!(
        dut.vertex_kick_rect().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0x48)
    );
    assert_eq!(
        dut.tex0_cfg().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0x80)
    );
    assert_eq!(
        dut.tex1_cfg().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0x88)
    );
    assert_eq!(
        dut.cc_mode().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0xC0)
    );
    assert_eq!(
        dut.const_color().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0xC8)
    );
    assert_eq!(
        dut.render_mode().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0x180)
    );
    assert_eq!(
        dut.z_range().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0x188)
    );
    assert_eq!(
        dut.stipple_pattern().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0x190)
    );
    assert_eq!(
        dut.fb_config().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0x200)
    );
    assert_eq!(
        dut.fb_display().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0x208)
    );
    assert_eq!(
        dut.fb_control().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0x218)
    );
    assert_eq!(
        dut.mem_fill().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0x220)
    );
    assert_eq!(
        dut.perf_timestamp().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0x280)
    );
    assert_eq!(
        dut.mem_addr().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0x380)
    );
    assert_eq!(
        dut.mem_data().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0x388)
    );
    assert_eq!(
        dut.id().as_ptr() as *mut u8,
        base_addr.wrapping_byte_add(0x3F8)
    );
}
