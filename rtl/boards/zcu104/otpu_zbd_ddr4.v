// The PL SODIMM's controller as a cell of the ZCU104's block design (boards/zcu104/vivado/
// bd_zcu104.tcl, cell "ddr4", an RTL module reference; Verilog, as a module reference's top
// must be): AMD's DDR4 IP otpu_ddr4 (MIG, PG150; boards/zcu104/vivado/mig.tcl) with its native
// user interface, which otpu_mig_mux drives. The IP's own block design cell offers only its AXI
// interface, so the native one comes onto the canvas through this module.
// Interfaces: C0_DDR4 (the SODIMM) and C0_SYS_CLK (its 300 MHz reference), made external by the
// block design; the MIG's board-flow constraints place their pins. sys_rst is the board's
// CPU_RESET (high when pressed): the MIG resets from it and holds app_rdy low until it has
// calibrated, so a PS reset keeps the SODIMM calibrated.
module otpu_zbd_ddr4 (
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 sys_rst RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
  input  wire         sys_rst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_clock:1.0 C0_SYS_CLK CLK_P" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME C0_SYS_CLK, FREQ_HZ 300000000" *)
  input  wire         c0_sys_clk_p,
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_clock:1.0 C0_SYS_CLK CLK_N" *)
  input  wire         c0_sys_clk_n,
  // the SODIMM as the block design and the hardware platform (.xsa) describe it: the MIG's own
  // settings (mig.tcl's board preset; bd_zcu104.tcl stops on a difference)
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 ACT_N" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME C0_DDR4, MEMORY_TYPE SODIMMs, MEMORY_PART MTA8ATF51264HZ-2G1, DATA_WIDTH 64, TIMEPERIOD_PS 938, CAS_LATENCY 15, CAS_WRITE_LATENCY 14, DATA_MASK_ENABLED true, CS_ENABLED true, SLOT Single, MEM_ADDR_MAP ROW_COLUMN_BANK, BURST_LENGTH 8" *)
  output wire         c0_ddr4_act_n,
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 ADR" *)
  output wire [16:0]  c0_ddr4_adr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 BA" *)
  output wire [1:0]   c0_ddr4_ba,
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 BG" *)
  output wire [1:0]   c0_ddr4_bg,
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 CKE" *)
  output wire [0:0]   c0_ddr4_cke,
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 ODT" *)
  output wire [0:0]   c0_ddr4_odt,
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 CS_N" *)
  output wire [0:0]   c0_ddr4_cs_n,
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 CK_T" *)
  output wire [0:0]   c0_ddr4_ck_t,
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 CK_C" *)
  output wire [0:0]   c0_ddr4_ck_c,
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 RESET_N" *)
  output wire         c0_ddr4_reset_n,
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 DM_N" *)
  inout  wire [7:0]   c0_ddr4_dm_dbi_n,
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 DQ" *)
  inout  wire [63:0]  c0_ddr4_dq,
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 DQS_T" *)
  inout  wire [7:0]   c0_ddr4_dqs_t,
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 DQS_C" *)
  inout  wire [7:0]   c0_ddr4_dqs_c,
  // the native user interface, in ui_clk (the memory clock / 4)
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ui_clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_RESET ui_rst, FREQ_HZ 266524520" *)
  output wire         ui_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 ui_rst RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
  output wire         ui_rst,
  output wire         calib_done,           // c0_init_calib_complete
  input  wire [28:0]  app_addr,
  input  wire [2:0]   app_cmd,
  input  wire         app_en,
  input  wire         app_hi_pri,
  output wire         app_rdy,
  input  wire [511:0] app_wdf_data,
  input  wire [63:0]  app_wdf_mask,
  input  wire         app_wdf_wren,
  input  wire         app_wdf_end,
  output wire         app_wdf_rdy,
  output wire [511:0] app_rd_data,
  output wire         app_rd_data_valid
);
  otpu_ddr4 u_mig (
    .sys_rst(sys_rst),
    .c0_sys_clk_p(c0_sys_clk_p), .c0_sys_clk_n(c0_sys_clk_n),
    .c0_init_calib_complete(calib_done),
    .c0_ddr4_act_n(c0_ddr4_act_n), .c0_ddr4_adr(c0_ddr4_adr), .c0_ddr4_ba(c0_ddr4_ba),
    .c0_ddr4_bg(c0_ddr4_bg), .c0_ddr4_cke(c0_ddr4_cke), .c0_ddr4_odt(c0_ddr4_odt),
    .c0_ddr4_cs_n(c0_ddr4_cs_n), .c0_ddr4_ck_t(c0_ddr4_ck_t), .c0_ddr4_ck_c(c0_ddr4_ck_c),
    .c0_ddr4_reset_n(c0_ddr4_reset_n), .c0_ddr4_dm_dbi_n(c0_ddr4_dm_dbi_n),
    .c0_ddr4_dq(c0_ddr4_dq), .c0_ddr4_dqs_t(c0_ddr4_dqs_t), .c0_ddr4_dqs_c(c0_ddr4_dqs_c),
    .c0_ddr4_ui_clk(ui_clk), .c0_ddr4_ui_clk_sync_rst(ui_rst),
    .c0_ddr4_app_addr(app_addr), .c0_ddr4_app_cmd(app_cmd), .c0_ddr4_app_en(app_en),
    .c0_ddr4_app_hi_pri(app_hi_pri), .c0_ddr4_app_rdy(app_rdy),
    .c0_ddr4_app_wdf_data(app_wdf_data), .c0_ddr4_app_wdf_mask(app_wdf_mask),
    .c0_ddr4_app_wdf_wren(app_wdf_wren), .c0_ddr4_app_wdf_end(app_wdf_end),
    .c0_ddr4_app_wdf_rdy(app_wdf_rdy),
    .c0_ddr4_app_rd_data(app_rd_data), .c0_ddr4_app_rd_data_valid(app_rd_data_valid),
    .c0_ddr4_app_rd_data_end(),
    .addn_ui_clkout1(), .dbg_clk(), .dbg_bus()
  );
endmodule
