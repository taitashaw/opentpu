// FPGA top for the AMD ZCU104 (xczu7ev-ffvc1156-2-e; boards/zcu104/vivado/create_project.tcl):
// the board's pins around the block design otpu_zbd (boards/zcu104/vivado/bd_zcu104.tcl), which
// holds the whole design:
//   - tpu (otpu_zbd_tpu): the card's system otpu_native_sys, as on the YPCB-00338: the
//     accelerator otpu_board at the card's parameters (targets/zcu104.toml: the same [arch], the
//     same arch_hash, so the same programs and results) and each channel's otpu_mem_ch;
//   - merge (otpu_zbd_mux): otpu_mig_mux, the two channels' four controller ports onto the MIG's
//     one user interface;
//   - ddr4 (otpu_zbd_ddr4): the PL DDR4 SODIMM behind AMD's DDR4 controller otpu_ddr4 (MIG,
//     PG150; boards/zcu104/vivado/mig.tcl), one DDR4-2133 x64 channel of 17.06 GB/s in place of
//     the card's two DDR3-1066 x64 channels of 8.5 GB/s each;
//   - the PS as the host (in XDMA's place), the core clocks, the AXI CDMA for the host's copies
//     (in the role of XDMA's DMA master), the SYSMONE4, the control interconnect.
//
// Clocks: pl_clk0 (100 MHz) feeds the block design's MMCM: core_clk 133.33 MHz, core_clk2x
// 266.67 MHz (the TMEM's pumped RAMs, TMEM_PMP 1), xclk 177.78 MHz (the PS's AXI ports and the
// CDMA: the card's xdma_aclk). The SODIMM's 300 MHz reference (c0_sys_clk_p/n) feeds the MIG,
// whose ui_clk (266.5 MHz) is both channels' controller side (the card's LiteDRAM sys_clk).
// otpu_mem_ch crosses between core_clk, xclk and ui_clk; constraints/otpu_top_zcu104.tcl and the
// card's otpu_mem_ch.tcl constrain the crossings.
// Resets: core_rst from the block design (MMCM lock, the PS's pl_resetn0), xrst likewise in
// xclk; the MIG resets from CPU_RESET (the board's push button) and holds app_rdy low until it
// has calibrated, so a PS reset keeps the SODIMM calibrated.
module otpu_fpga_top_zcu104 (
  // board (UG1267; constraints/zcu104_pins.xdc)
  input  logic        cpu_reset,            // M11, the CPU_RESET push button, high when pressed
  output logic [3:0]  led,                  // D5 D6 A5 B5, GPIO_LED_0..3
  // the PL DDR4 SODIMM and its 300 MHz reference (the MIG's board-flow constraints place them)
  input  logic        c0_sys_clk_p,
  input  logic        c0_sys_clk_n,
  output logic        c0_ddr4_act_n,
  output logic [16:0] c0_ddr4_adr,
  output logic [1:0]  c0_ddr4_ba,
  output logic [1:0]  c0_ddr4_bg,
  output logic [0:0]  c0_ddr4_cke,
  output logic [0:0]  c0_ddr4_odt,
  output logic [0:0]  c0_ddr4_cs_n,
  output logic [0:0]  c0_ddr4_ck_t,
  output logic [0:0]  c0_ddr4_ck_c,
  output logic        c0_ddr4_reset_n,
  inout  wire  [7:0]  c0_ddr4_dm_dbi_n,
  inout  wire  [63:0] c0_ddr4_dq,
  inout  wire  [7:0]  c0_ddr4_dqs_t,
  inout  wire  [7:0]  c0_ddr4_dqs_c
);
  otpu_zbd_wrapper u_bd (
    .cpu_reset, .led,
    .C0_SYS_CLK_clk_p(c0_sys_clk_p), .C0_SYS_CLK_clk_n(c0_sys_clk_n),
    .C0_DDR4_act_n(c0_ddr4_act_n), .C0_DDR4_adr(c0_ddr4_adr), .C0_DDR4_ba(c0_ddr4_ba),
    .C0_DDR4_bg(c0_ddr4_bg), .C0_DDR4_cke(c0_ddr4_cke), .C0_DDR4_odt(c0_ddr4_odt),
    .C0_DDR4_cs_n(c0_ddr4_cs_n), .C0_DDR4_ck_t(c0_ddr4_ck_t), .C0_DDR4_ck_c(c0_ddr4_ck_c),
    .C0_DDR4_reset_n(c0_ddr4_reset_n), .C0_DDR4_dm_n(c0_ddr4_dm_dbi_n),
    .C0_DDR4_dq(c0_ddr4_dq), .C0_DDR4_dqs_t(c0_ddr4_dqs_t), .C0_DDR4_dqs_c(c0_ddr4_dqs_c)
  );
endmodule
