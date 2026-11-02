# Clock-domain crossings of the ZCU104's design outside otpu_mem_ch (whose own are in the card's
# otpu_mem_ch.tcl, scoped to the module, reused as it is): the block design's cell tpu
# (otpu_zbd_tpu, the card's system otpu_native_sys and its glue). Unmanaged Tcl,
# read in implementation only and late (PROCESSING_ORDER LATE: after the IP's constraints, on the
# netlist synthesis made), because it selects cells by clock and by fan-out. The card's
# otpu_top_native.tcl without the LiteDRAM core's sections.
#
# The clocks: core_clk, core_clk2x and xclk come from one MMCM on the PS's pl_clk0, so Vivado
# relates them; the channels' controller clock (the MIG's ui_clk) comes from the SODIMM's 300 MHz
# oscillator and is asynchronous to them, but nothing declares it so: no set_clock_groups and no
# clock-to-clock false path, which would take priority over otpu_mem_ch's set_max_delay
# -datapath_only and leave its crossings untimed. Every path between two of the clocks is
# therefore a max delay without clock skew, here, in otpu_mem_ch.tcl or in the SmartConnect's own
# constraints (the control registers, xclk -> core_clk).
#
# otpu_native_sys sits in the block design (u_bd/otpu_zbd_i/tpu/inst/u_sys); its path is looked
# up by its module, so the cell's names in the block design may change.
set sys [get_cells -quiet -hierarchical -filter {ORIG_REF_NAME == otpu_native_sys || REF_NAME == otpu_native_sys}]
if {[llength $sys] != 1} {
  puts "CRITICAL WARNING: \[otpu_top_zcu104.tcl\] otpu_native_sys is '$sys', expected one instance: crossings unconstrained"
}
set tpu [get_property -quiet PARENT $sys]
# The clocks by the pins of otpu_mem_ch $sys/u_ch0, the ones its scoped constraints use.
set c_core [get_clocks -quiet -of_objects [get_pins -quiet $sys/u_ch0/clk]]
set c_ucl  [get_clocks -quiet -of_objects [get_pins -quiet $sys/u_ch0/uclk]]
set c_x    [get_clocks -quiet -of_objects [get_pins -quiet $sys/u_ch0/xclk]]
foreach v {c_core c_ucl c_x} {
  if {[llength [set $v]] != 1} {
    puts "CRITICAL WARNING: \[otpu_top_zcu104.tcl\] $v is '[set $v]', expected one clock: crossings unconstrained"
  }
}
set t_core [get_property -quiet -min PERIOD $c_core]
set t_ucl  [get_property -quiet -min PERIOD $c_ucl]
set t_x    [get_property -quiet -min PERIOD $c_x]

# ---- the SODIMM's calibration flag (the MIG's c0_init_calib_complete, ui_clk) into the
# accelerator's synchronizers (STATUS CALIB0/1; 2 flip-flops, ASYNC_REG): one core_clk period,
# datapath only. No ECC flags here (ded is tied low).
set s1 [get_cells -quiet -hier -filter "NAME =~ $sys/u_board/cal_s1_reg*"]
if {[llength $s1] && [llength $c_ucl] == 1 && [llength $c_core] == 1} {
  set_max_delay -datapath_only -from $c_ucl -to $s1 $t_core
  puts "otpu_top_zcu104.tcl: calibration flag, [llength $s1] synchronizer cells"
  # CDC-11 (one launch flop into two destination synchronizers): the one controller's flag feeds
  # both channels' CALIB bits. It only rises once calibration is done and stays high; the two bits
  # may see it a core cycle apart, and the control block only acts once both are set.
  set cal_src [get_pins -quiet -filter {IS_LEAF && REF_PIN_NAME == C} -of_objects [all_fanin -quiet -startpoints_only -flat -only_cells [get_pins -quiet -of_objects $s1 -filter {REF_PIN_NAME == D}]]]
  if {[llength $cal_src]} {
    if {[catch {create_waiver -type CDC -id {CDC-11} -user "otpu_zbd_tpu" -description "the MIG's calibration-done flag (static once set) into both channels' CALIB synchronizers" -from $cal_src -to [get_pins -quiet -of_objects $s1 -filter {REF_PIN_NAME == D}]} msg]} {
      puts "CRITICAL WARNING: \[otpu_top_zcu104.tcl\] CDC-11 waiver for the calibration flag not created: $msg"
    }
  }
} else {
  puts "CRITICAL WARNING: \[otpu_top_zcu104.tcl\] calibration flag: [llength $s1] synchronizer cells"
}

# ---- the control SmartConnect's reset (xrst, xclk) into core_clk (lrs1 / lrs2: the control
# master's reset for otpu_axil_iso), 2 flip-flops (ASYNC_REG): one core_clk period, datapath only
set lrs1 [get_cells -quiet $tpu/lrs1_reg]
if {[llength $lrs1] && [llength $c_x] == 1 && [llength $c_core] == 1} {
  set_max_delay -datapath_only -from $c_x -to $lrs1 $t_core
} else {
  puts "CRITICAL WARNING: \[otpu_top_zcu104.tcl\] the control master's reset: [llength $lrs1] synchronizer cells"
}

# ---- report_cdc waivers for the CDMA's read data. Each channel's host read-data FIFO u_xr
# (distributed RAM, written in the controller clock) is read asynchronously onto its R channel
# (x_rdata, x_rid, x_rresp, x_rlast), which otpu_axi_split2 muxes combinationally into
# otpu_dma_split's register slice (XREG 1); its paths are limited to one xclk period by
# otpu_mem_ch.tcl (-through the RAM's outputs). The endpoints are outside the module, so the
# waivers are here, from the RAMs' write clocks to exactly the endpoints the RAMs' outputs reach
# outside u_ch0 / u_ch1. Safe by the pointer protocol: the R channel takes a beat only with
# x_rvalid, the FIFO's registered not-empty in xclk, and an entry is written two controller-clock
# cycles before its write pointer crosses and not rewritten before the read pointer crosses back.
set xr_ram [get_cells -quiet -hierarchical -filter "NAME =~ $sys/u_ch?/u_xr/mem_reg*"]
set xr_src [get_pins -quiet -filter {IS_LEAF && REF_PIN_NAME == CLK} -of_objects $xr_ram]
set xr_out [get_pins -quiet -filter {IS_LEAF && DIRECTION == OUT} -of_objects $xr_ram]
set xr_dst {}
if {[llength $xr_out]} {
  set xr_dst [filter [all_fanout -quiet -from $xr_out -endpoints_only -flat] "NAME !~ $sys/u_ch?/*"]
}
if {[llength $xr_src] && [llength $xr_dst]} {
  foreach id {CDC-1 CDC-4 CDC-13 CDC-14 CDC-15 CDC-16 CDC-26} {
    if {[catch {create_waiver -type CDC -id $id -user "otpu_native_sys" -description "otpu_mem_ch u_xr's head (distributed RAM, written in the controller clock) read asynchronously onto the CDMA's R channel through otpu_axi_split2; taken only with x_rvalid, the FIFO's registered not-empty in xclk, when the entry is stable" -from $xr_src -to $xr_dst} msg]} {
      puts "CRITICAL WARNING: \[otpu_top_zcu104.tcl\] $id waiver for the host's read data not created: $msg"
    }
  }
} else {
  puts "CRITICAL WARNING: \[otpu_top_zcu104.tcl\] host read-data waivers: [llength $xr_src] RAM clock pins, [llength $xr_dst] endpoints"
}

# ---- TIMING-9 (unknown CDC logic: a crossing under set_max_delay -datapath_only with no
# double-registered synchronizer at the capture side) names no cells; it flags the FIFO heads
# above and in otpu_mem_ch.tcl, read across the clocks by design and covered by the report_cdc
# waivers. The waiver takes the whole check, so a new crossing of that kind has to show up in
# report_cdc (which build.tcl writes, reports/cdc.rpt) rather than here.
if {[catch {create_waiver -type METHODOLOGY -id {TIMING-9} -user "otpu_native_sys" -description "otpu_mem_ch's FIFO heads (distributed RAM read asynchronously across the clocks, guarded by the gray pointers) and the host's read data from them; each crossing is waived in report_cdc by its two ends"} msg]} {
  puts "CRITICAL WARNING: \[otpu_top_zcu104.tcl\] TIMING-9 waiver not created: $msg"
}
puts "otpu_top_zcu104.tcl: otpu_native_sys $sys"
puts "otpu_top_zcu104: core [get_property -quiet NAME $c_core] $t_core ns, ui [get_property -quiet NAME $c_ucl] $t_ucl ns, x [get_property -quiet NAME $c_x] $t_x ns"
