# The PL SODIMM's controller: AMD's DDR4 IP (MIG, PG150) as the ZCU104 board file presets it
# (XilinxBoardStore zcu104/1.1 preset.xml: SODIMM MTA8ATF51264HZ-2G1, 64 bits, tCK 938 ps =
# DDR4-2133, 300 MHz input clock clk_300mhz), with its native user interface (no AXI): one
# command a 512-bit beat in ui_clk (memory clock / 4, 266.5 MHz), what otpu_mig_mux drives.
# Sourced by create_project.tcl (and ip_probe.tcl) in a project whose board_part is the ZCU104.
#   ORDERING Strict: commands run in the order the UI takes them. otpu_mem_ch counts a write as
#     visible once the controller has taken it (n_wdone) and relies on a later read of the same
#     beat reaching the controller behind it; in order, the read can never pass the write.
#   No ECC (the SODIMM is 64 bits), data mask on (the module has DM; otpu_mem_ch writes whole
#     beats all the same), no user refresh / ZQ ports, no debug port.

# the newest installed version of an IP
proc mig_vlnv {} {
  set defs [lsort -decreasing [get_ipdefs -all "xilinx.com:ip:ddr4:*"]]
  if {[llength $defs] == 0} { error "IP ddr4 not found in this Vivado installation" }
  return [lindex $defs 0]
}

proc otpu_create_mig {dir} {
  file mkdir $dir
  set ip [create_ip -vlnv [mig_vlnv] -module_name otpu_ddr4 -dir $dir]
  set mig [get_ips otpu_ddr4]
  set_property -dict [list \
    CONFIG.C0_DDR4_BOARD_INTERFACE {ddr4_sdram} \
    CONFIG.C0_CLOCK_BOARD_INTERFACE {clk_300mhz} \
  ] $mig
  set_property -dict [list \
    CONFIG.C0.DDR4_AxiSelection {false} \
    CONFIG.C0.DDR4_Ordering {Strict} \
    CONFIG.C0.DDR4_isCustom {false} \
    CONFIG.Debug_Signal {Disable} \
  ] $mig
  # the preset's values, checked: the build's numbers (17.06 GB/s, the address map) assume them
  foreach {k want} {C0.DDR4_MemoryPart MTA8ATF51264HZ-2G1 C0.DDR4_DataWidth 64
                    C0.DDR4_TimePeriod 938 C0.DDR4_InputClockPeriod 3335
                    C0.DDR4_AxiSelection false C0.DDR4_Ordering Strict C0.DDR4_Ecc false} {
    set got [get_property CONFIG.$k $mig]
    if {![string equal -nocase $got $want]} { error "otpu_ddr4: CONFIG.$k is '$got', expected '$want'" }
  }
  puts "otpu_ddr4: [get_property CONFIG.C0.DDR4_MemoryPart $mig],\
    [get_property CONFIG.C0.DDR4_DataWidth $mig] bits, tCK [get_property CONFIG.C0.DDR4_TimePeriod $mig] ps,\
    address map [get_property CONFIG.C0.DDR4_Mem_Add_Map $mig], ordering [get_property CONFIG.C0.DDR4_Ordering $mig]"
  return $mig
}
