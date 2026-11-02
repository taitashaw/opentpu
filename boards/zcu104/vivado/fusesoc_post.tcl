# FuseSoC (opentpu.core, target zcu104): after mig.tcl and bd_zcu104.tcl are sourced (the block
# design makes the MIG its cell ddr4 instantiates), wrap the block design and add the constraints
# that create_project.tcl adds (the late unmanaged Tcl among them, which FuseSoC copies as user
# files beside this one).
set here [file normalize [file dirname [info script]]]
set src [file normalize $here/../../..]
set wrap [make_wrapper -files [get_files otpu_zbd.bd] -top]
add_files -norecurse $wrap
add_files -fileset constrs_1 -norecurse $here/act_uram.xdc
set_property USED_IN_IMPLEMENTATION false [get_files $here/act_uram.xdc]
set late [list $src/boards/ypcb-00338/constraints/otpu_mem_ch.tcl \
  $src/boards/zcu104/constraints/otpu_top_zcu104.tcl $src/boards/ypcb-00338/constraints/otpu_clk2x.tcl]
add_files -fileset constrs_1 -norecurse $late
set_property SCOPED_TO_REF otpu_mem_ch [get_files $src/boards/ypcb-00338/constraints/otpu_mem_ch.tcl]
set_property PROCESSING_ORDER LATE [get_files $late]
set_property USED_IN_SYNTHESIS false [get_files $late]
