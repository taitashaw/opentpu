# Build the ZCU104 bitstream: synthesis, implementation (opt, place, phys_opt, route, post-route
# phys_opt), reports and bitstream. The card's build.tcl (boards/ypcb-00338/vivado) without its
# board's placement scripts and PCIe fix-ups.
#   vivado -mode batch -source build.tcl -tclargs [OUT_DIR] [JOBS] [impl|full]
# With "impl", the existing synthesis (and IP runs) are kept and only implementation reruns.
# Expects the project from create_project.tcl. Outputs in OUT_DIR/reports and
#   OUT_DIR/otpu.bit          the bitstream (JTAG, or the PS's FSBL)
#   OUT_DIR/otpu.bin          the same for Linux's FPGA manager (fpgautil -b otpu.bin)
#   OUT_DIR/otpu_zcu104.xsa   the hardware platform (PS configuration, address map, bitstream)
#                             for the PS's software (Vitis, PetaLinux)

set here [file normalize [file dirname [info script]]]
set root [file normalize $here/../../..]
set out [expr {[llength $argv] > 0 && [lindex $argv 0] ne "" ? [file normalize [lindex $argv 0]] : "$root/build/zcu104"}]
set jobs [expr {[llength $argv] > 1 ? [lindex $argv 1] : 8}]
set impl_only [expr {[lindex $argv 2] eq "impl"}]
# act_uram.xdc's memories: 16 activation RAM pieces x 4 + the trace buffer's 4
set URAM_MIN 68

open_project $out/otpu.xpr
file mkdir $out/reports
set fast [expr {[info exists ::env(OTPU_FAST)] && $::env(OTPU_FAST) eq "1"}]

if {!$impl_only} {
  # OTPU_BD_OOC=1: the block design out of context per IP instead (the AMD IP as in the
  # 2026-10-29 build). The module references then get runs of their own too (Vivado keeps their
  # GENERATE_SYNTH_CHECKPOINT read-only), so tpu, merge and ddr4 take synth_1's strategy and
  # retiming, and tpu act_uram.xdc (ooc_cell_pre.tcl); the SYNTHESIS define comes from sources_1
  set bd_ooc [expr {[info exists ::env(OTPU_BD_OOC)] && $::env(OTPU_BD_OOC) eq "1"}]
  if {$bd_ooc} { set_property synth_checkpoint_mode Hierarchical [get_files otpu_zbd.bd] }
  # ---- IP: the MIG's out-of-context run first, the block design's output products
  foreach ipf [list [get_files otpu_ddr4.xci] [get_files otpu_zbd.bd]] {
    generate_target all $ipf
    export_ip_user_files -of_objects $ipf -no_script -sync -force -quiet
    # (the block design synthesizes globally, in synth_1: bd_zcu104.tcl)
    if {[string match *.xci $ipf] || [get_property SYNTH_CHECKPOINT_MODE $ipf] ne "None"} { create_ip_run $ipf }
  }
  if {$bd_ooc} {
    set s1 [get_runs synth_1]
    foreach c {tpu merge ddr4} {
      set r [get_runs otpu_zbd_${c}_0_synth_1]
      set_property strategy [get_property strategy $s1] $r
      set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING [get_property STEPS.SYNTH_DESIGN.ARGS.RETIMING $s1] $r
      if {$c eq "tpu"} { set_property STEPS.SYNTH_DESIGN.TCL.PRE $here/ooc_cell_pre.tcl $r }
      puts "$r: [get_property strategy $r], retiming [get_property STEPS.SYNTH_DESIGN.ARGS.RETIMING $r]"
    }
  }

  # ---- synthesis
  reset_run synth_1
  launch_runs synth_1 -jobs $jobs
  wait_on_run synth_1
  if {[get_property PROGRESS [get_runs synth_1]] != "100%"} { error "synthesis failed" }
  # A memory that synthesis turned into a block RAM with a registered read address (Synth
  # 8-6430) returns the old word when a write and a read of one address meet, where the RTL's
  # asynchronous read returns the new one: the simulation no longer describes the hardware.
  # Stop the build (the card's check).
  set fh [open $out/otpu.runs/synth_1/runme.log]; set slog [read $fh]; close $fh
  set coll [regexp -all -inline {Synth 8-6430\] The Block RAM "[^"]*"} $slog]
  if {[llength $coll]} {
    error "synthesis made asynchronous-read memories block RAMs with a read-address register\
           (collisions differ from the RTL): [join $coll {; }] -- give them\
           (* ram_style = \"distributed\" *)"
  }
  open_run synth_1
  # act_uram.xdc took: the activation RAM and the trace in UltraRAM, not in LUTs
  set nuram [llength [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ BLOCKRAM.URAM.*}]]
  puts "URAM288: $nuram (act_uram.xdc expects at least $URAM_MIN)"
  if {$nuram < $URAM_MIN} {
    error "synthesis placed $nuram URAM288, expected at least $URAM_MIN: act_uram.xdc's patterns\
           no longer match the activation RAM / trace memories (they stay in LUTs / block RAM)"
  }
  # (the design is in the block design: u_bd/otpu_zbd_i/tpu/inst/u_sys/u_board/...)
  report_utilization -hierarchical -hierarchical_depth 8 -file $out/reports/synth_util_hier.rpt
  report_timing_summary -max_paths 20 -file $out/reports/synth_timing.rpt
  close_design
} else {
  if {[get_property PROGRESS [get_runs synth_1]] != "100%"} { error "impl: no finished synthesis to reuse" }
  set_property NEEDS_REFRESH false [get_runs synth_1]
}

# ---- implementation to the routed design
puts "impl_1: place_design -directive [get_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE [get_runs impl_1]],\
  phys_opt_design -directive [get_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE [get_runs impl_1]]"
if {!$fast} { set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1] }
reset_run impl_1
launch_runs impl_1 -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} { error "implementation failed" }
# the top's crossings (constraints/otpu_top_zcu104.tcl) ran on this netlist: an unmanaged Tcl
# constraint's error is only a critical warning in the run, so its summary line must be there
set fh [open $out/otpu.runs/impl_1/runme.log]; set ilog [read $fh]; close $fh
foreach {what re} {otpu_top_zcu104.tcl {otpu_top_zcu104: core \S+ [0-9.]+ ns, ui \S+ [0-9.]+ ns, x \S+ [0-9.]+ ns}
                   otpu_clk2x.tcl {otpu_clk2x.tcl: \d+ pumped TMEM RAMs}} {
  if {![regexp $re $ilog]} { error "$what: its summary line is missing from impl_1/runme.log (it did not run, or failed)" }
}
set cw [regexp -all -inline -line {^CRITICAL WARNING: \[otpu_\S+\.tcl\].*$} $ilog]
if {[llength $cw]} { error "the board's constraints reported: [join $cw { | }]" }
open_run impl_1

report_timing_summary -max_paths 50 -report_unconstrained -warn_on_violation \
  -file $out/reports/timing_summary.rpt
report_timing -max_paths 30 -sort_by group -nworst 1 -file $out/reports/timing_worst.rpt
report_design_analysis -congestion -file $out/reports/congestion.rpt
report_clock_interaction -file $out/reports/clock_interaction.rpt
report_clocks -file $out/reports/clocks.rpt
report_cdc -details -file $out/reports/cdc.rpt
report_utilization -file $out/reports/util.rpt
report_utilization -hierarchical -hierarchical_depth 9 -file $out/reports/util_hier.rpt
report_drc -file $out/reports/drc.rpt
report_methodology -file $out/reports/methodology.rpt
report_power -hierarchical_depth 12 -file $out/reports/power.rpt
report_power -hierarchical_depth 12 -format xml -file $out/reports/power.xml
if {[catch {exec env PYTHONPATH=$root python3 -m opentpu.host.power $out/reports/power.xml \
              -o $out/reports/power.json} msg]} {
  puts "power.json not written ($msg)"
} else { puts $msg }
report_io -file $out/reports/io.rpt

# per-clock worst slack in one line each, and the totals (setup, hold, pulse width)
set fh [open $out/reports/SUMMARY.txt w]
set wns [get_property SLACK [lindex [get_timing_paths -max_paths 1 -nworst 1 -setup] 0]]
set whs [get_property SLACK [lindex [get_timing_paths -max_paths 1 -nworst 1 -hold] 0]]
set tfh [open $out/reports/timing_summary.rpt]; set ts [read $tfh]; close $tfh
set met [string match "*All user specified timing constraints are met.*" $ts]
puts $fh "WNS $wns ns   WHS $whs ns   [expr {$met ? {all user specified timing constraints met (setup, hold, pulse width)} : {TIMING NOT MET}}]"
puts $fh "URAM288 [llength [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ BLOCKRAM.URAM.*}]]"
foreach clk [get_clocks] {
  set p [lindex [get_timing_paths -max_paths 1 -nworst 1 -setup -to $clk] 0]
  if {$p ne ""} {
    set period [get_property PERIOD $clk]
    set slack [get_property SLACK $p]
    set fmax [expr {$slack eq "" ? "n/a" : [format %.1f [expr {1000.0 / ($period - $slack)}]]}]
    puts $fh [format "%-48s period %7.3f ns  slack %8s ns  fmax %s MHz" $clk $period $slack $fmax]
  }
}
close $fh
puts [exec cat $out/reports/SUMMARY.txt]

# ---- bitstream, written from the routed design opened above
write_bitstream -force $out/otpu.bit
if {[llength [get_debug_cores -quiet]]} { write_debug_probes -force $out/otpu.ltx }
write_cfgmem -force -format bin -interface SMAPx32 -disablebitswap -loadbit "up 0x0 $out/otpu.bit" \
  $out/otpu.bin
# (-include_bit takes only a bitstream the run itself wrote: the .bit sits beside it)
write_hw_platform -fixed -force -file $out/otpu_zcu104.xsa
puts "bitstream: $out/otpu.bit"
if {$wns < 0 || $whs < 0} { puts "WARNING: timing not met (WNS $wns ns, WHS $whs ns) -- see reports/timing_summary.rpt" }
