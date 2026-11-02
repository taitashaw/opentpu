// Simulation model of the ZCU104's SODIMM controller as otpu_mig_mux drives it: AMD's DDR4 IP
// (MIG, PG150) with its native user interface in 4:1 mode (one 512-bit beat a command, BL8),
// ORDERING Strict, no ECC (boards/zcu104/vivado/mig.tcl). The memory is both channels' images
// interleaved as otpu_mig_mux maps them: app_addr = {beat, channel, 3'b000} (8-byte columns), so
// channel c's beat a is mem[c][a] (checked: app_addr's column bits are 0, the beat is in range).
//   - app_rdy is randomly withheld (+axi_stall=percent) and drops while QD commands are held;
//     app_wdf_rdy likewise (its own draw) and while WD beats of write data wait for commands.
//   - A write command needs its data in the write data buffer already or in the same cycle (the
//     strict reading of PG150's UI write timing; checked). app_wdf_end must come with every
//     app_wdf_wren (one beat a burst; checked).
//   - Commands are performed in the order taken, one a cycle, each 1 to WJ cycles after it was
//     taken or later, never during a busy stretch (refresh, ZQ: +ldn_busy=N per mille a cycle,
//     a 10-49 cycle pause). A write merges its data under the mask (app_wdf_mask bit 1: the byte
//     is left as it is); a read returns the memory as it is when it is performed, LAT to LAT + 7
//     cycles later (+axi_lat=N), in command order, one beat a cycle, never held back.
// With IMG = 1 the memory loads from <dir>/ch<2 SID + c>.bin and dumps to <dir>/ch<2 SID + c>_out.bin
// on dump (otpu_ldn_model's formats).
module otpu_mig_model #(
  parameter int BEATS = 1 << 12,          // per channel
  parameter int LAT   = 20,
  parameter int SID   = 0,
  parameter bit IMG   = 1'b0,
  parameter int QD    = 16,
  parameter int WD    = 16,
  parameter int WJ    = 12
) (
  input  logic          clk,
  input  logic          rst,
  input  logic [28:0]   app_addr,
  input  logic [2:0]    app_cmd,
  input  logic          app_en,
  output logic          app_rdy,
  input  logic [511:0]  app_wdf_data,
  input  logic [63:0]   app_wdf_mask,
  input  logic          app_wdf_wren,
  input  logic          app_wdf_end,
  output logic          app_wdf_rdy,
  output logic [511:0]  app_rd_data,
  output logic          app_rd_data_valid,
  output logic          app_rd_data_end,
  input  logic          dump
);
  logic [511:0] mem [2][BEATS];
  int stall = 0, lat = LAT, busy = 2;
  longint cyc = 0, n_rd = 0, n_wr = 0, n_busy = 0, n_part = 0, tret = 0, texec = 0, busy_until = 0;
  longint n_wcmd = 0, n_wdat = 0;          // write commands / write data beats taken
  typedef struct { longint t; logic we; bit c; logic [24:0] a; } c_t;
  typedef struct { logic [511:0] d; logic [63:0] m; } w_t;
  typedef struct { longint t; logic [511:0] d; } r_t;
  c_t cq [$];
  w_t wq [$];
  r_t rq [$];
  assign app_rd_data_end = app_rd_data_valid;

  always @(posedge clk) begin
    if (rst) begin
      cq.delete(); wq.delete(); rq.delete();
      app_rdy <= 1'b0; app_wdf_rdy <= 1'b0; app_rd_data_valid <= 1'b0;
      n_wcmd = 0; n_wdat = 0; texec = cyc; tret = cyc; busy_until = cyc;
    end else begin
      // write data taken in the cycle now ending
      if (app_wdf_wren && !app_wdf_end) $fatal(1, "otpu_mig_model: app_wdf_wren without app_wdf_end (one beat a burst)");
      if (app_wdf_wren && app_wdf_rdy) begin
        wq.push_back('{app_wdf_data, app_wdf_mask});
        n_wdat++;
      end
      // the command taken
      if (app_en && app_rdy) begin
        longint t;
        if (app_cmd != 3'b000 && app_cmd != 3'b001) $fatal(1, "otpu_mig_model: app_cmd %b", app_cmd);
        if (app_addr[2:0] != 3'b000) $fatal(1, "otpu_mig_model: app_addr %h not on a beat (column bits %b)", app_addr, app_addr[2:0]);
        if (app_addr[28:4] >= BEATS) $fatal(1, "otpu_mig_model: beat %0d of channel %0d beyond the memory", app_addr[28:4], app_addr[3]);
        if (app_cmd == 3'b000) begin
          n_wcmd++;
          if (n_wcmd > n_wdat) $fatal(1, "otpu_mig_model: write command %0d taken before its data (%0d beats in)", n_wcmd, n_wdat);
        end
        t = cyc + 1 + longint'($urandom % WJ);
        if (t <= texec) t = texec + 1;
        texec = t;
        cq.push_back('{t, app_cmd == 3'b000, app_addr[3], app_addr[28:4]});
      end
      // a busy stretch, or the head command performed
      if (busy != 0 && cyc >= busy_until && ($urandom % 1000) < busy) begin
        busy_until = cyc + 10 + longint'($urandom % 40);
        n_busy++;
      end
      if (cq.size() != 0 && cq[0].t <= cyc && cyc >= busy_until) begin
        c_t h;
        h = cq.pop_front();
        if (h.we) begin
          w_t w;
          if (wq.size() == 0) $fatal(1, "otpu_mig_model: write performed with no data in the buffer");
          w = wq.pop_front();
          for (int k = 0; k < 64; k++)
            if (!w.m[k]) mem[h.c][h.a][8 * k +: 8] = w.d[8 * k +: 8];
          if (w.m != '0) n_part++;
          n_wr++;
        end else begin
          longint t;
          t = cyc + lat + longint'($urandom % 8);
          if (t <= tret) t = tret + 1;
          tret = t;
          rq.push_back('{t, mem[h.c][h.a]});
          n_rd++;
        end
      end
      app_rd_data_valid <= 1'b0;
      if (rq.size() != 0 && rq[0].t <= cyc) begin
        app_rd_data_valid <= 1'b1;
        app_rd_data <= rq[0].d;
        void'(rq.pop_front());
      end
      app_rdy <= cq.size() < QD && ($urandom % 100) >= stall;
      // write data waiting for commands: data taken, commands not yet
      app_wdf_rdy <= (n_wdat - n_wcmd) < WD && ($urandom % 100) >= stall;
    end
    cyc++;
  end

  string dir;
  integer fd, nread;
  logic [31:0] words [BEATS * 16];
  initial begin
    void'($value$plusargs("axi_stall=%d", stall));
    void'($value$plusargs("axi_lat=%d", lat));
    void'($value$plusargs("ldn_busy=%d", busy));
    for (int c = 0; c < 2; c++) for (int i = 0; i < BEATS; i++) mem[c][i] = '0;
    if (IMG && $value$plusargs("dir=%s", dir)) begin
      for (int c = 0; c < 2; c++) begin
        for (int i = 0; i < BEATS * 16; i++) words[i] = '0;
        fd = $fopen($sformatf("%s/ch%0d.bin", dir, 2 * SID + c), "rb");
        if (fd != 0) begin
          nread = $fread(words, fd);
          $fclose(fd);
        end
        for (int i = 0; i < BEATS * 16; i++) mem[c][i / 16][32 * (i % 16) +: 32] = words[i];
      end
    end
  end
  // dump may span several of this clock's cycles (it is driven in the core clock): its first
  logic dump_q = 1'b0;
  always @(posedge clk) dump_q <= dump;
  always @(posedge clk) if (dump && !dump_q) begin
    $display("MIG s%0d rd=%0d wr=%0d partial=%0d busy=%0d", SID, n_rd, n_wr, n_part, n_busy);
    if (IMG) begin
      for (int c = 0; c < 2; c++) begin
        fd = $fopen($sformatf("%s/ch%0d_out.bin", dir, 2 * SID + c), "wb");
        for (int i = 0; i < BEATS * 16; i++) $fwrite(fd, "%u", mem[c][i / 16][32 * (i % 16) +: 32]);
        $fclose(fd);
      end
    end
  end
endmodule
