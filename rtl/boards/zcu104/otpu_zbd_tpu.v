// The accelerator as a cell of the ZCU104's block design (boards/zcu104/vivado/bd_zcu104.tcl,
// cell "tpu", an RTL module reference; Verilog, as a module reference's top must be): the card's
// system otpu_native_sys with the glue around it:
//   - the resets: synchronous, active high, one register each (otpu_mem_ch crosses them
//     registered), and the control master's reset (lrs1 / lrs2) in core_clk;
//   - the board's LEDs.
// Its parameters are the target's (targets/zcu104.toml): create_project.tcl sets them on the
// cell; the defaults are the same values (ARCH_HASH: python3 -m opentpu.target hash zcu104), so a
// block design built without them (FuseSoC) builds the same accelerator. The card's bit
// parameters are integers here (0 or 1): a block design cell's parameters are numbers.
// Bus interfaces (inferred from the port names): s_axi_ctl, AXI4-Lite, the control registers
// (core_clk); s_axi_dma, AXI4 128 bits without IDs, the CDMA's copies to and from the card's
// DRAM (xclk; 37 address bits for the 0x10_0000_0000 window, of which the low 32 are the card's
// address, bit 31 the channel). The ports are the ones the block design exported before the
// accelerator moved onto it (M_AXI_CTL, M_AXI_DMA), so the SmartConnects build as before. The
// channels' controller ports (c_*, ui_clk) go to the "merge" cell (otpu_zbd_mux), flattened from
// otpu_native_sys's [channel][port] arrays: bit 2 channel + port.
module otpu_zbd_tpu #(
  parameter integer MCOLS = 4,              // MXU columns (activation rows per weight chunk)
  parameter integer ACT_ROWS = 16,          // ACT RAM rows (> MCOLS: MM replay, one weight pass)
  parameter integer VPU_CL = 2,             // VPU lanes with the composite functions (exp2, ...)
  parameter integer MXU_IMPL = 2,           // MXU dot product: 2 systolic, the only one
  parameter integer MXU_E = 4,              // MXU epilogue lanes: MCOLS (full rate)
  parameter integer TMEM_IMPL = 3,          // TMEM: 3 one copy (docs/tmem_nocopy.md)
  parameter integer TMEM_RQ = 0,
  parameter integer TMEM_NSB = 2,           // TMEM_IMPL 3: RAMs a bank, the sub-bank's address
  parameter integer TMEM_SBP = 3,           //   bit, its hash, replays, true dual-port RAMs, the
  parameter integer TMEM_SBH = 0,           //   DMA's guests, the RAMs pumped at 2x (1: on
  parameter integer TMEM_RPL = 1,           //   clk_f, below), the read ports' ranks and
  parameter integer TMEM_TDP = 1,           //   RAM sides
  parameter integer TMEM_GST = 1,
  parameter integer TMEM_PMP = 1,
  parameter integer TMEM_PRK = 0,
  parameter integer TMEM_SDM = -1,
  parameter integer TMEM_WORDS = 65536,     // TMEM words (the target's [arch] TMEM_WORDS)
  parameter integer LANES = 8,              // VPU lanes / TMEM banks
  parameter integer ULANES = 8,             // TMEM lanes of the MXU and the quantizer
  parameter integer CORE_KHZ = 133333,      // core_clk as the block design makes it (CORE_KHZ register)
  parameter [31:0] BUILD_ID = 32'h00000000, // the git commit (BUILD_ID register)
  parameter integer DDR_MTS = 2133,         // the SODIMM's data rate (DDR_MTS register)
  parameter integer DSTEP = 1,              // the DMA's DSTEP datapath (CAPS bit6)
  parameter integer SEQ_WC = 1,             // otpu_seq's wait entries (CFG_UARCH bit24)
  parameter integer PLATFORM = 3,           // targets/zcu104.toml (CFG_PLATFORM)
  parameter [31:0] ARCH_HASH = 32'h4ffd1e17, // its arch_hash (CFG_HASH)
  parameter integer TRACE_DEPTH = 16384,    // trace records (a power of two; 0: no trace buffer)
  parameter integer COLL_GATHER = 0         // 0: the collective unit without GATHER
) (
  // ---- clocks and resets (the block design's clk_wiz_0, rst_core, rst_x; the MIG's ui_clk)
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi_ctl, ASSOCIATED_RESET core_rstn" *)
  input  wire          clk,                 // core_clk, 133.33 MHz
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_f CLK" *)
  input  wire          clk_f,               // core_clk2x: the TMEM's pumped RAMs (TMEM_PMP 1)
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 xclk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi_dma, ASSOCIATED_RESET xresetn" *)
  input  wire          xclk,                // the PS's AXI ports and the CDMA, 177.78 MHz
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 core_rstn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire          core_rstn,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 xresetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire          xresetn,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 uclk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_RESET urst" *)
  input  wire          uclk,                // the MIG's ui_clk: both channels' controller side
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 urst RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
  input  wire          urst,
  // ---- status in, LEDs out
  input  wire          calib_done,          // the MIG's c0_init_calib_complete (ui_clk)
  input  wire          mux_err,             // otpu_mig_mux: read data with no read outstanding
  input  wire [9:0]    device_temp,         // SYSMONE4 die-temperature code (core_clk)
  output wire [3:0]    led,                 // GPIO_LED_0..3
  // ---- s_axi_ctl: AXI4-Lite slave, the control registers (PS 0xA000_0000, 64 KB; core_clk)
  input  wire [31:0]   s_axi_ctl_awaddr,
  input  wire [2:0]    s_axi_ctl_awprot,    // unused
  input  wire          s_axi_ctl_awvalid,
  output wire          s_axi_ctl_awready,
  input  wire [31:0]   s_axi_ctl_wdata,
  input  wire [3:0]    s_axi_ctl_wstrb,
  input  wire          s_axi_ctl_wvalid,
  output wire          s_axi_ctl_wready,
  output wire [1:0]    s_axi_ctl_bresp,
  output wire          s_axi_ctl_bvalid,
  input  wire          s_axi_ctl_bready,
  input  wire [31:0]   s_axi_ctl_araddr,
  input  wire [2:0]    s_axi_ctl_arprot,    // unused
  input  wire          s_axi_ctl_arvalid,
  output wire          s_axi_ctl_arready,
  output wire [31:0]   s_axi_ctl_rdata,
  output wire [1:0]    s_axi_ctl_rresp,
  output wire          s_axi_ctl_rvalid,
  input  wire          s_axi_ctl_rready,
  // ---- s_axi_dma: AXI4 slave, 128 bits, no IDs (one ID, in order). The CDMA's bursts are INCR
  // of full-width beats (no DRE, aligned copies: otpu_mem_ch relies on it, as on XDMA's), so
  // size, burst, lock, cache, prot and qos are unused
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi_dma, NUM_READ_OUTSTANDING 8, NUM_WRITE_OUTSTANDING 8, MAX_BURST_LENGTH 256" *)
  input  wire [36:0]   s_axi_dma_awaddr,
  input  wire [7:0]    s_axi_dma_awlen,
  input  wire [2:0]    s_axi_dma_awsize,
  input  wire [1:0]    s_axi_dma_awburst,
  input  wire          s_axi_dma_awlock,
  input  wire [3:0]    s_axi_dma_awcache,
  input  wire [2:0]    s_axi_dma_awprot,
  input  wire [3:0]    s_axi_dma_awqos,
  input  wire          s_axi_dma_awvalid,
  output wire          s_axi_dma_awready,
  input  wire [127:0]  s_axi_dma_wdata,
  input  wire [15:0]   s_axi_dma_wstrb,
  input  wire          s_axi_dma_wlast,
  input  wire          s_axi_dma_wvalid,
  output wire          s_axi_dma_wready,
  output wire [1:0]    s_axi_dma_bresp,
  output wire          s_axi_dma_bvalid,
  input  wire          s_axi_dma_bready,
  input  wire [36:0]   s_axi_dma_araddr,
  input  wire [7:0]    s_axi_dma_arlen,
  input  wire [2:0]    s_axi_dma_arsize,
  input  wire [1:0]    s_axi_dma_arburst,
  input  wire          s_axi_dma_arlock,
  input  wire [3:0]    s_axi_dma_arcache,
  input  wire [2:0]    s_axi_dma_arprot,
  input  wire [3:0]    s_axi_dma_arqos,
  input  wire          s_axi_dma_arvalid,
  output wire          s_axi_dma_arready,
  output wire [127:0]  s_axi_dma_rdata,
  output wire [1:0]    s_axi_dma_rresp,
  output wire          s_axi_dma_rlast,
  output wire          s_axi_dma_rvalid,
  input  wire          s_axi_dma_rready,
  // ---- the channels' controller ports to otpu_zbd_mux (ui_clk), bit 2 channel + port
  output wire [3:0]    c_cmd_valid,
  input  wire [3:0]    c_cmd_ready,
  output wire [3:0]    c_cmd_we,
  output wire [99:0]   c_cmd_addr,
  output wire [3:0]    c_wdata_valid,
  input  wire [3:0]    c_wdata_ready,
  output wire [2047:0] c_wdata_data,
  output wire [255:0]  c_wdata_we,
  input  wire [3:0]    c_rdata_valid,
  input  wire [2047:0] c_rdata_data
);
  // resets: synchronous, active high, one register each (otpu_mem_ch crosses them registered)
  reg core_rst, xrst;
  always @(posedge clk) core_rst <= !core_rstn;
  always @(posedge xclk) xrst <= !xresetn;
  // the control SmartConnect's reset (rst_x's interconnect reset, xclk) in core_clk, where its
  // control master is (s_axi_ctl): the masters' side of otpu_axil_iso. Two flip-flops
  // (otpu_top_zcu104.tcl: one core_clk period from xclk); the reset lasts many cycles
  (* ASYNC_REG = "TRUE" *) reg lrs1 = 1'b1, lrs2 = 1'b1;
  always @(posedge clk) begin lrs1 <= xrst; lrs2 <= lrs1; end

  // the TMEM's RAMs pumped at 2x (TMEM_PMP 1) on core_clk2x (an MMCM output at twice core_clk,
  // rising with it); otherwise nothing runs at 2x and clk_f is unused
  wire clk_2x = TMEM_PMP == 1 ? clk_f : 1'b0;
  wire [2:0] board_led;
  wire [3:0] i2c_lo;                        // no I2C devices on the PL here: released, read high
  otpu_native_sys #(.MCOLS(MCOLS), .ACT_ROWS(ACT_ROWS), .VPU_CL(VPU_CL), .MXU_IMPL(MXU_IMPL),
                    .MXU_E(MXU_E), .LANES(LANES),
                    .TMEM_IMPL(TMEM_IMPL), .TMEM_RQ(TMEM_RQ),
                    .TMEM_NSB(TMEM_NSB), .TMEM_SBP(TMEM_SBP), .TMEM_SBH(TMEM_SBH), .TMEM_RPL(TMEM_RPL), .TMEM_TDP(TMEM_TDP),
                    .TMEM_GST(TMEM_GST), .TMEM_PMP(TMEM_PMP), .TMEM_PRK(TMEM_PRK), .TMEM_SDM(TMEM_SDM),
                    .TMEM_WORDS(TMEM_WORDS),
                    .ULANES(ULANES), .CORE_KHZ(CORE_KHZ), .BUILD_ID(BUILD_ID), .DDR_MTS(DDR_MTS),
                    .DSTEP(DSTEP), .HOSTCAL(1'b0), .XREG(1'b1),
                    .SEQ_WC(SEQ_WC), .PLATFORM(PLATFORM), .ARCH_HASH(ARCH_HASH),
                    .TRACE_DEPTH(TRACE_DEPTH), .COLL_GATHER(COLL_GATHER)) u_sys (
    .clk(clk), .clk_f(clk_2x), .rst(core_rst), .ctl_mrst(lrs2), .xclk(xclk), .xrst(xrst),
    // one controller calibrates both channels (STATUS CALIB0/1, ui_clk; otpu_board syncs them);
    // no ECC on the SODIMM
    .calib({2{calib_done}}), .ded(2'b00),
    .temp({device_temp, 2'b00}), .led(board_led), .i2c_lo(i2c_lo), .i2c_pin(5'b11111),
    .s_ctl_awaddr(s_axi_ctl_awaddr[11:0]), .s_ctl_awvalid(s_axi_ctl_awvalid),
    .s_ctl_awready(s_axi_ctl_awready), .s_ctl_wdata(s_axi_ctl_wdata),
    .s_ctl_wstrb(s_axi_ctl_wstrb), .s_ctl_wvalid(s_axi_ctl_wvalid),
    .s_ctl_wready(s_axi_ctl_wready), .s_ctl_bresp(s_axi_ctl_bresp),
    .s_ctl_bvalid(s_axi_ctl_bvalid), .s_ctl_bready(s_axi_ctl_bready),
    .s_ctl_araddr(s_axi_ctl_araddr[11:0]), .s_ctl_arvalid(s_axi_ctl_arvalid),
    .s_ctl_arready(s_axi_ctl_arready), .s_ctl_rdata(s_axi_ctl_rdata),
    .s_ctl_rresp(s_axi_ctl_rresp), .s_ctl_rvalid(s_axi_ctl_rvalid),
    .s_ctl_rready(s_axi_ctl_rready),
    .x_awvalid(s_axi_dma_awvalid), .x_awready(s_axi_dma_awready), .x_awid(4'd0),
    .x_awaddr(s_axi_dma_awaddr[31:0]), .x_awlen(s_axi_dma_awlen), .x_wvalid(s_axi_dma_wvalid),
    .x_wready(s_axi_dma_wready), .x_wdata(s_axi_dma_wdata), .x_wstrb(s_axi_dma_wstrb),
    .x_wlast(s_axi_dma_wlast), .x_bvalid(s_axi_dma_bvalid), .x_bready(s_axi_dma_bready),
    .x_bid(), .x_bresp(s_axi_dma_bresp), .x_arvalid(s_axi_dma_arvalid),
    .x_arready(s_axi_dma_arready), .x_arid(4'd0), .x_araddr(s_axi_dma_araddr[31:0]),
    .x_arlen(s_axi_dma_arlen), .x_rvalid(s_axi_dma_rvalid), .x_rready(s_axi_dma_rready),
    .x_rid(), .x_rdata(s_axi_dma_rdata), .x_rresp(s_axi_dma_rresp), .x_rlast(s_axi_dma_rlast),
    .uclk({2{uclk}}), .urst({2{urst}}),
    .c_cmd_valid(c_cmd_valid), .c_cmd_ready(c_cmd_ready), .c_cmd_we(c_cmd_we),
    .c_cmd_addr(c_cmd_addr), .c_wdata_valid(c_wdata_valid), .c_wdata_ready(c_wdata_ready),
    .c_wdata_data(c_wdata_data), .c_wdata_we(c_wdata_we), .c_rdata_valid(c_rdata_valid),
    .c_rdata_data(c_rdata_data));

  // LEDs: led[0] heartbeat, led[1] the SODIMM calibrated, led[2] the accelerator runs or halted
  // cleanly, led[3] otpu_mig_mux saw read data with no read outstanding (sticky until CPU_RESET)
  assign led = {mux_err, board_led[2] | board_led[1], calib_done, board_led[0]};
endmodule
