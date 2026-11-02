// Simulation model of the ZCU104's board memory behind the two channels' native ports n_*: per
// channel the board's bridge, otpu_mem_ch, as on the card, then the ZCU104's merge of the two
// channels' four controller ports, otpu_mig_mux (rtl/boards/zcu104), in front of a model of the
// SODIMM's controller (otpu_mig_model), in its one controller clock (the MIG's ui_clk).
// otpu_chmem's parameters and ports, so the board model (tb_board, MEM_NATIVE 3) takes it; this
// one runs the ZCU104's RTL between the accelerator and the controller.
//
// Clocks: the core clock is the caller's (tb_board: a period of 10 time units). The controller
// clock (266.5 MHz against a 133.33 MHz core on the board) has half periods of 3, 2, 3, 3 units in
// turn (5.5 on average, so its edges drift against the core's). The host's side of each bridge
// (xclk) is idle; its reset and the controller's follow the caller's rst through two flip-flops
// of their clocks.
// The controller model's arguments: +axi_stall=P (app_rdy / app_wdf_rdy withheld, percent),
// +axi_lat=N (read latency), +ldn_busy=N (refresh pauses, per mille), +axi_seed=N.
// PHYS = 1 only: the files are the channels' own memories (ch<c>.bin in, ch<c>_out.bin out).
// otpu_mig_mux's err (read data with no read outstanding) stops the simulation.
module otpu_migmem #(
  parameter int WORDS = 1 << 18,
  parameter int PHYS  = 0,
  parameter int LAT   = 20,              // minimum read latency (controller cycles)
  parameter int SID   = 0,               // the slice: its channels' files are ch<2 SID + c>
  parameter bit CHASH = 1'b1             // (otpu_native_mem's; unused: the images are physical)
) (
  input  logic                  clk,
  input  logic                  rst,
  input  logic [1:0]            n_cvalid,
  output logic [1:0]            n_cready,
  input  logic [1:0]            n_cwe,
  input  logic [1:0][24:0]      n_caddr,
  input  logic [1:0]            n_wvalid,
  output logic [1:0]            n_wready,
  input  logic [1:0][511:0]     n_wdata,
  input  logic [1:0][63:0]      n_wmask,
  output logic [1:0]            n_rvalid,
  output logic [1:0][511:0]     n_rdata,
  output logic [1:0][15:0]      n_wdone,
  output logic [1:0]            n_err,
  input  logic                  dump
);
  localparam int BEATS = WORDS / 32;     // per channel: WORDS / 2 words, 16 a beat
  initial if (PHYS != 1) $fatal(1, "otpu_migmem: PHYS = 1 only (the channels' own images)");

  logic uclk = 1'b0, xclk = 1'b0;
  always begin
    #3 uclk = 1'b1; #2 uclk = 1'b0; #3 uclk = 1'b1; #3 uclk = 1'b0;
  end
  always #4 xclk = ~xclk;
  logic xrst = 1'b1, xr1 = 1'b1;
  always @(posedge xclk) {xrst, xr1} <= {xr1, rst};
  logic urst = 1'b1, ur1 = 1'b1;
  always @(posedge uclk) {urst, ur1} <= {ur1, rst};

  initial begin
    int seed;
    if ($value$plusargs("axi_seed=%d", seed)) void'($urandom(seed));
  end

  logic [1:0][1:0]        cv, cr, cwe, wv, wr, rv;
  logic [1:0][1:0][24:0]  ca;
  logic [1:0][1:0][511:0] wd, rd;
  logic [1:0][1:0][63:0]  we;
  for (genvar c = 0; c < 2; c++) begin : g_ch
    otpu_mem_ch #(.XIDW(4)) u_ch (
      .clk, .rst,
      .n_cvalid(n_cvalid[c]), .n_cready(n_cready[c]), .n_cwe(n_cwe[c]), .n_caddr(n_caddr[c]),
      .n_wvalid(n_wvalid[c]), .n_wready(n_wready[c]), .n_wdata(n_wdata[c]), .n_wmask(n_wmask[c]),
      .n_rvalid(n_rvalid[c]), .n_rdata(n_rdata[c]), .n_wdone(n_wdone[c]), .n_err(n_err[c]),
      .xclk, .xrst,
      .x_awvalid(1'b0), .x_awready(), .x_awid(4'h0), .x_awaddr(32'h0), .x_awlen(8'h0),
      .x_wvalid(1'b0), .x_wready(), .x_wdata(128'h0), .x_wstrb(16'h0), .x_wlast(1'b0),
      .x_bvalid(), .x_bready(1'b1), .x_bid(), .x_bresp(),
      .x_arvalid(1'b0), .x_arready(), .x_arid(4'h0), .x_araddr(32'h0), .x_arlen(8'h0),
      .x_rvalid(), .x_rready(1'b1), .x_rid(), .x_rdata(), .x_rresp(), .x_rlast(),
      .uclk, .urst,
      .c_cmd_valid(cv[c]), .c_cmd_ready(cr[c]), .c_cmd_we(cwe[c]), .c_cmd_addr(ca[c]),
      .c_wdata_valid(wv[c]), .c_wdata_ready(wr[c]), .c_wdata_data(wd[c]), .c_wdata_we(we[c]),
      .c_rdata_valid(rv[c]), .c_rdata_data(rd[c]));
  end

  logic [28:0]  app_addr;
  logic [2:0]   app_cmd;
  logic         app_en, app_rdy, app_wdf_wren, app_wdf_end, app_wdf_rdy;
  logic [511:0] app_wdf_data, app_rd_data;
  logic [63:0]  app_wdf_mask;
  logic         app_rd_data_valid, app_rd_data_end, mux_err;
  otpu_mig_mux u_mux (
    .clk(uclk), .rst(urst),
    .c_cmd_valid(cv), .c_cmd_ready(cr), .c_cmd_we(cwe), .c_cmd_addr(ca),
    .c_wdata_valid(wv), .c_wdata_ready(wr), .c_wdata_data(wd), .c_wdata_we(we),
    .c_rdata_valid(rv), .c_rdata_data(rd),
    .app_addr, .app_cmd, .app_en, .app_rdy, .app_wdf_data, .app_wdf_mask, .app_wdf_wren,
    .app_wdf_end, .app_wdf_rdy, .app_rd_data, .app_rd_data_valid, .err(mux_err));
  otpu_mig_model #(.BEATS(BEATS), .LAT(LAT), .SID(SID), .IMG(1'b1)) u_mem (
    .clk(uclk), .rst(urst),
    .app_addr, .app_cmd, .app_en, .app_rdy, .app_wdf_data, .app_wdf_mask, .app_wdf_wren,
    .app_wdf_end, .app_wdf_rdy, .app_rd_data, .app_rd_data_valid, .app_rd_data_end, .dump);
  always @(posedge uclk) if (!urst && mux_err) $fatal(1, "otpu_migmem s%0d: otpu_mig_mux err (read data with no read outstanding)", SID);
endmodule
