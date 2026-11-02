# FuseSoC (opentpu.core, target zcu104): the ZCU104's board part, before the MIG and the block
# design are created (their board interfaces come from it). create_project.tcl does the same.
set_property board_part xilinx.com:zcu104:part0:1.1 [current_project]
set_property verilog_define {SYNTHESIS} [get_filesets sources_1]
