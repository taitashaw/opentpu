# Create the Vivado project for openTPU on the AMD ZCU104 (xczu7ev-ffvc1156-2-e): the block
# design otpu_zbd (bd_zcu104.tcl) with the card's system (otpu_native_sys, cell tpu), the merge
# (otpu_mig_mux, cell merge) and the PL DDR4 SODIMM's controller (mig.tcl, cell ddr4) on its
# canvas beside the PS, the top otpu_fpga_top_zcu104 (the board's pins).
#   vivado -mode batch -source create_project.tcl -tclargs [OUT_DIR] [BUILD_ID]
# OUT_DIR: default ../../../build/zcu104 (repository build/).
# BUILD_ID: 8 hex digits for the BUILD_ID register (default: the repository's git commit, else 0).
# The accelerator's parameters are the target's (targets/zcu104.toml, through opentpu/target.py
# "generics"): the card's [arch], so the same arch_hash and the same programs. They go to the
# block design's cell tpu (otpu_zbd_tpu), whose parameters are numbers.

set here [file normalize [file dirname [info script]]]
set root [file normalize $here/../../..]
set part xczu7ev-ffvc1156-2-e
set board xilinx.com:zcu104:part0:1.1
set out [expr {[llength $argv] > 0 && [lindex $argv 0] ne "" ? [file normalize [lindex $argv 0]] : "$root/build/zcu104"}]
set BUILD_ID [expr {[llength $argv] > 1 ? [lindex $argv 1] : ""}]
if {$BUILD_ID eq ""} {
  if {[catch {exec git -C $root rev-parse HEAD} BUILD_ID]} { set BUILD_ID 0 }
  set BUILD_ID [string range $BUILD_ID 0 7]
}
if {![regexp {^[0-9a-fA-F]{1,8}$} $BUILD_ID]} { error "BUILD_ID $BUILD_ID: 1 to 8 hex digits" }

# ---- the target: its RTL files and its parameters
proc target_cmd {args} {
  set fh [open "|env PYTHONPATH=$::root python3 -m opentpu.target $args" r]
  set t [string trim [read $fh]]
  close $fh
  return $t
}
set files [split [target_cmd files zcu104] "\n"]
array set T {}
foreach kv [target_cmd generics zcu104] {
  if {![regexp {^([A-Z0-9_]+)=(.*)$} $kv -> k v]} { error "target generics: '$kv'" }
  set T($k) $v
}
# the accelerator's parameters (otpu_zbd_tpu, the block design's cell tpu), from the target where
# it has them; the block design's core clock for CORE_KHZ (bd_zcu104.tcl: 1066.67 MHz / 8). The
# cell takes numbers: the card's bits as 0 or 1, BUILD_ID and ARCH_HASH as 0x and 8 hex digits
set CORE_MHZ 133.33
set CLK2X [expr {[info exists T(TMEM_PMP)] && $T(TMEM_PMP) == 1}]
set CORE_KHZ [expr {round(100000.0 * 32 / 3 / 8)}]
set bits {TMEM_RQ TMEM_RPL TMEM_TDP TMEM_GST DSTEP SEQ_WC COLL_GATHER}
set ints {MCOLS ACT_ROWS VPU_CL MXU_IMPL MXU_E TMEM_IMPL TMEM_NSB TMEM_SBP TMEM_SBH TMEM_PMP
          TMEM_PRK TMEM_SDM TMEM_WORDS LANES ULANES DDR_MTS PLATFORM TRACE_DEPTH}
set otpu_tpu_params [dict create CORE_KHZ $CORE_KHZ BUILD_ID [format 0x%08X 0x$BUILD_ID]]
foreach k [concat $ints $bits] { if {[info exists T($k)]} { dict set otpu_tpu_params $k $T($k) } }
if {![info exists T(ARCH_HASH)]} { error "target zcu104: no ARCH_HASH" }
dict set otpu_tpu_params ARCH_HASH [format 0x%08X $T(ARCH_HASH)]
# the card's release default (create_project.tcl of the YPCB-00338): the collective unit without
# GATHER, unless the environment asks (COLL_GATHER=1)
if {![info exists T(COLL_GATHER)]} {
  set cg [expr {[info exists ::env(COLL_GATHER)] && $::env(COLL_GATHER) eq "1" ? 1 : 0}]
  dict set otpu_tpu_params COLL_GATHER $cg
}
puts "tpu parameters: $otpu_tpu_params"

create_project -force otpu $out -part $part
set_property board_part $board [current_project]
if {[info exists ::env(OTPU_IP_CACHE)] && $::env(OTPU_IP_CACHE) ne ""} {
  file mkdir $::env(OTPU_IP_CACHE)
  config_ip_cache -use_cache_location $::env(OTPU_IP_CACHE)
}
set_property target_language Verilog [current_project]
set_property default_lib xil_defaultlib [current_project]

# ---- RTL: the accelerator, the card's system, the MIG merge (SystemVerilog), the block design's
# cells around them (otpu_zbd_*.v, Verilog-2001) and the top
foreach f $files {
  add_files -norecurse $root/$f
  if {[file extension $f] eq ".sv"} { set_property file_type SystemVerilog [get_files $root/$f] }
}
# SYNTHESIS removes the simulation-only checks and dumps
set_property verilog_define {SYNTHESIS} [get_filesets sources_1]

# ---- IP: the SODIMM's controller (instantiated by the block design's cell ddr4), then the
# block design
source $here/mig.tcl
otpu_create_mig $out/ip
update_compile_order -fileset sources_1
source $here/bd_zcu104.tcl
make_wrapper -files [get_files otpu_zbd.bd] -top
add_files -norecurse [glob $out/otpu.gen/sources_1/bd/otpu_zbd/hdl/otpu_zbd_wrapper.v]
set_property top otpu_fpga_top_zcu104 [current_fileset]

# ---- constraints: the board's pins; the memory placement (act_uram.xdc, synthesis only: it
# names the RTL's memories, which synthesis turns into URAM288s); then, after the IP's
# constraints, as unmanaged Tcl on the implemented netlist, each otpu_mem_ch's crossings (the
# card's file, scoped to the module), the top's (otpu_top_zcu104.tcl) and the paths between
# core_clk and core_clk2x (the card's otpu_clk2x.tcl)
set cons $root/boards/zcu104/constraints
set ccons $root/boards/ypcb-00338/constraints
add_files -fileset constrs_1 -norecurse [list $cons/zcu104_pins.xdc $here/act_uram.xdc]
set_property USED_IN_IMPLEMENTATION false [get_files $here/act_uram.xdc]
set late [list $ccons/otpu_mem_ch.tcl $cons/otpu_top_zcu104.tcl]
if {$CLK2X} { lappend late $ccons/otpu_clk2x.tcl }
add_files -fileset constrs_1 -norecurse $late
set_property SCOPED_TO_REF otpu_mem_ch [get_files $ccons/otpu_mem_ch.tcl]
set_property PROCESSING_ORDER LATE [get_files $late]
set_property USED_IN_SYNTHESIS false [get_files $late]
foreach f $late {
  if {![string match -nocase *tcl* [get_property FILE_TYPE [get_files $f]]]} {
    error "$f: FILE_TYPE [get_property FILE_TYPE [get_files $f]], expected TCL (unmanaged)"
  }
}

# ---- strategies: the card's (timing-driven: the accelerator is the critical part)
if {[info exists ::env(OTPU_FAST)] && $::env(OTPU_FAST) eq "1"} {
  set_property strategy {Vivado Synthesis Defaults} [get_runs synth_1]
  set_property strategy {Vivado Implementation Defaults} [get_runs impl_1]
} else {
  set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
  set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]
  set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
}
set_property report_strategy {No Reports} [get_runs synth_1]
set_property report_strategy {No Reports} [get_runs impl_1]

puts "project created in $out (ZCU104, DDR4-$T(DDR_MTS) SODIMM, MIG; CLK2X $CLK2X)"
