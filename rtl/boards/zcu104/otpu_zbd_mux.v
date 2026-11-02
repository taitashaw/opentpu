// The merge of the two channels' four controller ports onto the MIG's one user interface as a
// cell of the ZCU104's block design (boards/zcu104/vivado/bd_zcu104.tcl, cell "merge", an RTL
// module reference; Verilog, as a module reference's top must be): otpu_mig_mux with its
// [channel][port] arrays flattened (bit 2 channel + port, as otpu_zbd_tpu's), in the MIG's
// ui_clk, and the MIG's app_hi_pri held low.
module otpu_zbd_mux #(
  parameter integer TAGD = 128              // reads in flight the tag FIFO holds (a power of two)
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_RESET rst" *)
  input  wire          clk,                 // the MIG's ui_clk
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
  input  wire          rst,                 // its ui_clk_sync_rst (synchronous, high)
  // the channels' controller ports (otpu_zbd_tpu)
  input  wire [3:0]    c_cmd_valid,
  output wire [3:0]    c_cmd_ready,
  input  wire [3:0]    c_cmd_we,
  input  wire [99:0]   c_cmd_addr,
  input  wire [3:0]    c_wdata_valid,
  output wire [3:0]    c_wdata_ready,
  input  wire [2047:0] c_wdata_data,
  input  wire [255:0]  c_wdata_we,          // 1 = write the byte
  output wire [3:0]    c_rdata_valid,
  output wire [2047:0] c_rdata_data,
  // the MIG's native user interface
  output wire [28:0]   app_addr,
  output wire [2:0]    app_cmd,
  output wire          app_en,
  output wire          app_hi_pri,
  input  wire          app_rdy,
  output wire [511:0]  app_wdf_data,
  output wire [63:0]   app_wdf_mask,        // 1 = leave the byte as it is in memory (the MIG's sense)
  output wire          app_wdf_wren,
  output wire          app_wdf_end,
  input  wire          app_wdf_rdy,
  input  wire [511:0]  app_rd_data,
  input  wire          app_rd_data_valid,
  output wire          err                  // read data with no read outstanding (sticky)
);
  assign app_hi_pri = 1'b0;
  otpu_mig_mux #(.TAGD(TAGD)) u_mux (
    .clk(clk), .rst(rst),
    .c_cmd_valid(c_cmd_valid), .c_cmd_ready(c_cmd_ready), .c_cmd_we(c_cmd_we),
    .c_cmd_addr(c_cmd_addr), .c_wdata_valid(c_wdata_valid), .c_wdata_ready(c_wdata_ready),
    .c_wdata_data(c_wdata_data), .c_wdata_we(c_wdata_we), .c_rdata_valid(c_rdata_valid),
    .c_rdata_data(c_rdata_data),
    .app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en), .app_rdy(app_rdy),
    .app_wdf_data(app_wdf_data), .app_wdf_mask(app_wdf_mask), .app_wdf_wren(app_wdf_wren),
    .app_wdf_end(app_wdf_end), .app_wdf_rdy(app_wdf_rdy), .app_rd_data(app_rd_data),
    .app_rd_data_valid(app_rd_data_valid), .err(err));
endmodule
