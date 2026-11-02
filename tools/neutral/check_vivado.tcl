# Read the neutral netlist (tools/neutral/export.py) in Vivado and synthesize it out of context
# for a part: a vendor tool takes the file as it is and maps its behavioural RAMs and multipliers
# itself. Writes <dir>/vivado_util.rpt and prints the cell counts.
#
#   vivado -mode batch -nojournal -source tools/neutral/check_vivado.tcl \
#     -tclargs build/neutral/zcu104 xczu7ev-ffvc1156-2-e
set dir [file normalize [lindex $argv 0]]
set part [lindex $argv 1]
read_verilog $dir/otpu_native_sys.v
synth_design -top otpu_native_sys -part $part -mode out_of_context -flatten_hierarchy none
report_utilization -file $dir/vivado_util.rpt
set n [llength [get_cells -hierarchical -filter {IS_PRIMITIVE}]]
puts "check_vivado: $part, [llength [get_cells -hierarchical -filter {REF_NAME =~ LUT*}]] LUT,\
  [llength [get_cells -hierarchical -filter {REF_NAME =~ FD*}]] FF,\
  [llength [get_cells -hierarchical -filter {REF_NAME =~ DSP*}]] DSP,\
  [llength [get_cells -hierarchical -filter {REF_NAME =~ RAMB*}]] RAMB, $n primitives"
