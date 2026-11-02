# Does the accelerator fit the XCZU7EV? Out-of-context synthesis of otpu_native_sys (otpu_board:
# the slice, its DRAM adapter, the control block and trace; one otpu_mem_ch per channel; the host
# DMA's split) at the target's parameters, without the PS, the MIG or the block design. Minutes
# against the full build's hours; prints the utilization by hierarchy.
#   vivado -mode batch -source fit_check.tcl -tclargs OUT_DIR "K=V K=V ..." [URAM_XDC]
# The generics are the target's, reshaped for otpu_native_sys by the caller (from
# `python3 -m opentpu.target generics zcu104`; run_vivado.sh does not run this script). URAM_XDC: an XDC of ram_style overrides read before synthesis.

set here [file normalize [file dirname [info script]]]
set root [file normalize $here/../../..]
set out [file normalize [lindex $argv 0]]
set gens [lindex $argv 1]
set uxdc [lindex $argv 2]
file mkdir $out
set part xczu7ev-ffvc1156-2-e
set_part $part
set fh [open "|env PYTHONPATH=$root python3 -m opentpu.target files zcu104" r]
set files [split [string trim [read $fh]] "\n"]
close $fh
foreach f $files {
  if {[string match *otpu_fpga_top* $f] || [string match *otpu_mig_mux* $f] || [string match *otpu_zbd_* $f]} { continue }
  read_verilog -sv $root/$f
}
if {$uxdc ne ""} { read_xdc $uxdc }
set g {}
foreach kv $gens { lappend g -generic $kv }
synth_design -top otpu_native_sys -part $part -mode out_of_context -verilog_define SYNTHESIS {*}$g
create_clock -period 7.500 -name core_clk [get_ports clk]
create_clock -period 3.750 -name core_clk2x [get_ports clk_f]
create_clock -period 3.750 -name ui_clk [get_ports {uclk[*]}]
create_clock -period 5.625 -name xclk [get_ports xclk]
report_utilization -file $out/fit_util.rpt
report_utilization -hierarchical -hierarchical_depth 6 -file $out/fit_util_hier.rpt
report_ram_utilization -file $out/fit_ram.rpt
puts [exec head -60 $out/fit_util.rpt]
