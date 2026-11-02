# Generate the MIG's instantiation template in a throwaway project and print its ports and the
# configuration values otpu_mig_mux depends on (the address width, the data width, ui_clk).
#   vivado -mode batch -source ip_probe.tcl -tclargs OUT_DIR
set here [file normalize [file dirname [info script]]]
set out [file normalize [lindex $argv 0]]
file mkdir $out
create_project -force probe $out/probe -part xczu7ev-ffvc1156-2-e
set_property board_part xilinx.com:zcu104:part0:1.1 [current_project]
source $here/mig.tcl
set mig [otpu_create_mig $out/ip]
generate_target instantiation_template [get_files otpu_ddr4.xci]
foreach k [lsort [list_property $mig CONFIG.*]] {
  if {[regexp -nocase {ADDR|DATA|WIDTH|ORDER|MAP|PERIOD|FREQ|PART|MASK|ECC|Mem_Add|CLKOUT} $k]} {
    puts "CFG $k = [get_property $k $mig]"
  }
}
set veo [glob -nocomplain $out/ip/otpu_ddr4/otpu_ddr4.veo]
puts "VEO $veo"
if {[llength $veo]} {
  set fh [open [lindex $veo 0]]; set t [read $fh]; close $fh
  foreach l [split $t "\n"] { if {[regexp {^\s*\.} $l]} { puts "PORT $l" } }
}
