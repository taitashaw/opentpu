// The ZCU104's memory: the slice's two channels (otpu_native_sys: one otpu_mem_ch per channel,
// each with two LiteDRAM-native controller ports, [channel][port]) merged onto the one PL DDR4
// SODIMM behind AMD's DDR4 controller (MIG, PG150; boards/zcu104/vivado/mig.tcl), in its ui_clk.
//
// The card has two DDR3-1066 channels of 8.5 GB/s; the SODIMM is one DDR4-2133 channel of 17.06
// GB/s, one 512-bit beat a ui_clk cycle (266.5 MHz). The slice moves one 64-byte beat a core
// cycle on each channel (otpu_native_dram: a 128-byte chunk is one beat on each), so at 133.33 MHz
// the two channels together ask for the SODIMM's peak, as they asked for the two DDR3 channels'.
//
// Address map: channel c's beat a (otpu_mem_ch's 25-bit c_cmd_addr, 2 GiB a channel) is the
// SODIMM's beat {a, c}, so the two halves of a chunk are adjacent and a stream of chunks is a
// stream of consecutive beats (the MIG's ROW_COLUMN_BANK map then turns consecutive beats into
// consecutive bank groups). app_addr counts 8-byte columns: {a, c, 3'b0}, 29 bits for 4 GiB.
// The host's view (bit 31 of its DMA address the channel: otpu_axi_split2) is the card's.
//
// The port contract otpu_mem_ch expects (LiteDRAM's native port, rtl/shell/otpu_mem_ch.sv):
//   - commands (we, beat) with valid / ready, each port's in order;
//   - a write's data at the head of its port's write-data stream by the time its command is
//     (otpu_mem_ch enqueues them together), taken in write-command order: here in the same cycle
//     as the command, so the command and data heads always belong together;
//   - read data in each port's command order, without backpressure (c_rdata_valid, and one data
//     bus: every port's c_rdata_data is the same word).
// The MIG takes commands in order (ORDERING Strict) and returns read data in command order, so
// one tag a read (its channel and port, pushed when the read is taken, popped when its data
// returns) routes the data back, and every port sees its reads in its order.
//
// The arbiter takes one command a cycle, round robin over the four ports, into a two-entry queue
// (registered: the arbiter's decision does not depend on the MIG's app_rdy in the same cycle, so
// no combinational path runs from the MIG into otpu_mem_ch). A read is taken only while the tag
// FIFO has room for it (TAGD reads between the arbiter and their data). The queue's head goes to
// the MIG: a write's data first or with its command (app_wdf_wren, then app_en: the MIG's write
// data buffer takes data before its command), a read's command alone.
//
// err: read data with no read outstanding (the MIG broke its contract). Sticky until reset.
module otpu_mig_mux #(
  parameter int TAGD = 128               // reads in flight the tag FIFO holds (a power of two)
) (
  input  logic                    clk,   // the MIG's ui_clk
  input  logic                    rst,   // its ui_clk_sync_rst (synchronous, high)
  // the four controller ports, [channel][port] (otpu_mem_ch's c_*)
  input  logic [1:0][1:0]         c_cmd_valid,
  output logic [1:0][1:0]         c_cmd_ready,
  input  logic [1:0][1:0]         c_cmd_we,
  input  logic [1:0][1:0][24:0]   c_cmd_addr,
  input  logic [1:0][1:0]         c_wdata_valid,
  output logic [1:0][1:0]         c_wdata_ready,
  input  logic [1:0][1:0][511:0]  c_wdata_data,
  input  logic [1:0][1:0][63:0]   c_wdata_we,     // 1 = write the byte
  output logic [1:0][1:0]         c_rdata_valid,
  output logic [1:0][1:0][511:0]  c_rdata_data,
  // the MIG's user interface
  output logic [28:0]             app_addr,
  output logic [2:0]              app_cmd,
  output logic                    app_en,
  input  logic                    app_rdy,
  output logic [511:0]            app_wdf_data,
  output logic [63:0]             app_wdf_mask,   // 1 = leave the byte as it is in memory (the MIG's sense)
  output logic                    app_wdf_wren,
  output logic                    app_wdf_end,
  input  logic                    app_wdf_rdy,
  input  logic [511:0]            app_rd_data,
  input  logic                    app_rd_data_valid,
  output logic                    err
);
  localparam int TW = $clog2(TAGD);
  localparam logic [2:0] CMD_WR = 3'b000, CMD_RD = 3'b001;

  // ---- the ports, flattened: i = 2c + p
  logic [3:0]         pv, pwe, pwv;
  logic [3:0][24:0]   pa;
  logic [3:0][511:0]  pd;
  logic [3:0][63:0]   pm;
  for (genvar i = 0; i < 4; i++) begin : g_flat
    assign pv[i]  = c_cmd_valid[i / 2][i % 2];
    assign pwe[i] = c_cmd_we[i / 2][i % 2];
    assign pa[i]  = c_cmd_addr[i / 2][i % 2];
    assign pwv[i] = c_wdata_valid[i / 2][i % 2];
    assign pd[i]  = c_wdata_data[i / 2][i % 2];
    assign pm[i]  = c_wdata_we[i / 2][i % 2];
  end

  // ---- the queue between the arbiter and the MIG: two entries, registered count
  typedef struct packed {
    logic         we;
    logic [28:0]  addr;
    logic [63:0]  mask;
    logic [511:0] data;
  } ent_t;
  ent_t        q [2];
  logic        q_wp, q_rp;
  logic [1:0]  q_n;                       // entries held
  logic        q_dat;                     // the head's write data already taken by the MIG
  logic        h_v, h_cmd, h_dat, h_pop;
  ent_t        h;

  // ---- tags: the port of every read between the arbiter and its data
  logic [1:0]  tag_mem [TAGD];
  logic [TW:0] tag_n;                     // reads taken, data not yet returned
  logic [TW-1:0] tag_wp, tag_rp;

  // ---- arbiter: round robin, one command a cycle while the queue has room (registered)
  logic [1:0]  rr;                        // the port that goes first
  logic [3:0]  elig;
  logic        any, take;
  logic [1:0]  sel;
  wire q_room = q_n != 2'd2;
  wire t_room = tag_n < TAGD;
  for (genvar i = 0; i < 4; i++) begin : g_elig
    // a write needs its data at the head too; a read needs a tag
    assign elig[i] = pv[i] && (pwe[i] ? pwv[i] : t_room);
  end
  always_comb begin
    any = 1'b0;
    sel = rr;
    for (int k = 3; k >= 0; k--) begin   // the first eligible port from rr on wins
      if (elig[(rr + k) % 4]) begin any = 1'b1; sel = 2'((rr + k) % 4); end
    end
  end
  assign take = any && q_room;
  for (genvar i = 0; i < 4; i++) begin : g_rdy
    assign c_cmd_ready[i / 2][i % 2]   = take && sel == i;
    assign c_wdata_ready[i / 2][i % 2] = take && sel == i && pwe[i];
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      rr <= 2'd0;
      q_wp <= 1'b0;
    end else if (take) begin
      rr <= sel + 2'd1;
      q_wp <= !q_wp;
    end
    if (take) begin
      q[q_wp].we   <= pwe[sel];
      q[q_wp].addr <= {pa[sel], sel[1], 3'b000};     // {a, c, column 0}: sel = 2c + p
      q[q_wp].mask <= ~pm[sel];
      q[q_wp].data <= pd[sel];
    end
  end

  // ---- the head to the MIG: a write's data first (or with its command), then the command
  assign h     = q[q_rp];
  assign h_v   = q_n != 2'd0;
  assign app_wdf_wren = h_v && h.we && !q_dat;
  assign app_wdf_end  = app_wdf_wren;     // one 512-bit beat a burst (4:1, BL8)
  assign app_wdf_data = h.data;
  assign app_wdf_mask = h.mask;
  assign h_dat  = app_wdf_wren && app_wdf_rdy;
  assign app_en = h_v && (!h.we || q_dat || h_dat);
  assign app_cmd  = h.we ? CMD_WR : CMD_RD;
  assign app_addr = h.addr;
  assign h_cmd  = app_en && app_rdy;
  assign h_pop  = h_cmd;                   // a write's command goes only with or after its data

  always_ff @(posedge clk) begin
    if (rst) begin
      q_rp <= 1'b0;
      q_n <= 2'd0;
      q_dat <= 1'b0;
    end else begin
      if (h_pop) q_rp <= !q_rp;
      q_n <= q_n + 2'(take) - 2'(h_pop);
      if (h_pop) q_dat <= 1'b0;
      else if (h_dat) q_dat <= 1'b1;
    end
  end

  // ---- read tags: pushed when the arbiter takes a read (queue order = MIG order), popped with
  // its data
  wire t_push = take && !pwe[sel];
  wire t_pop  = app_rd_data_valid && tag_n != 0;
  always_ff @(posedge clk) begin
    if (t_push) tag_mem[tag_wp] <= sel;
    if (rst) begin
      tag_wp <= '0;
      tag_rp <= '0;
      tag_n <= '0;
    end else begin
      if (t_push) tag_wp <= tag_wp + 1'b1;
      if (t_pop) tag_rp <= tag_rp + 1'b1;
      tag_n <= tag_n + (TW + 1)'(t_push) - (TW + 1)'(t_pop);
    end
  end

  // ---- read data back to its port, from a register (one data bus for all four)
  logic [3:0]   r_v;
  logic [511:0] r_d;
  always_ff @(posedge clk) begin
    r_d <= app_rd_data;
    for (int i = 0; i < 4; i++) r_v[i] <= !rst && t_pop && tag_mem[tag_rp] == i;
    if (rst) err <= 1'b0;
    else if (app_rd_data_valid && tag_n == 0) err <= 1'b1;
  end
  for (genvar i = 0; i < 4; i++) begin : g_rd
    assign c_rdata_valid[i / 2][i % 2] = r_v[i];
    assign c_rdata_data[i / 2][i % 2]  = r_d;
  end

`ifndef SYNTHESIS
  always @(posedge clk) if (!rst) begin
    if (app_rd_data_valid && tag_n == 0) $error("otpu_mig_mux: read data with no read outstanding");
  end
`endif
endmodule
