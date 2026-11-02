# Block design "otpu_zbd" for the ZCU104 (create_project.tcl): the whole design but the board's
# pins. The card's block design (boards/ypcb-00338/vivado/bd_native.tcl) with the PS in XDMA's
# place, and with the accelerator, the merge and the SODIMM's controller on the canvas as RTL
# module references (cells whose contents are this repository's RTL):
#   tpu    otpu_zbd_tpu: the card's system otpu_native_sys (the accelerator otpu_board and each
#          channel's otpu_mem_ch, where the accelerator and the CDMA meet), its resets and LEDs
#   merge  otpu_zbd_mux: otpu_mig_mux, the two channels' four controller ports onto the MIG's one
#          user interface
#   ddr4   otpu_zbd_ddr4: the MIG otpu_ddr4 (mig.tcl) with its native user interface (the IP's
#          own block design cell offers only AXI), DDR4-2133 x64, 17.06 GB/s
# and the IP around them: the PS as the host, the core clocks, resets, an AXI CDMA for the host's
# copies, the SYSMONE4 and the control interconnect. External ports (otpu_fpga_top_zcu104 names
# them for the board): C0_DDR4 (the SODIMM), C0_SYS_CLK (its 300 MHz reference), cpu_reset (the
# CPU_RESET push button, the MIG's reset), led[3:0].
#
# The host (Linux on the PS) sees, on M_AXI_HPM0_FPD:
#   0xA000_0000  64 KB  the control registers, tpu/s_axi_ctl (the card's BAR0 0x0:
#                       docs/observability.md)
#   0xA002_0000  64 KB  the AXI CDMA (PG034, simple mode): copies between the PS DDR (its 0x0 to
#                       0x7FFF_FFFF through S_AXI_HP0_FPD) and the card's DRAM (0x10_0000_0000
#                       + card address, tpu/s_axi_dma; bit 31 the channel: otpu_axi_split2),
#                       128-bit bursts of full-width beats (no DRE: 64-byte aligned copies,
#                       otpu_mem_ch's contract)
#   0xA003_0000  64 KB  the SYSMONE4 (the card's XADC at BAR0 0x30000)
# The CDMA's interrupt is pl_ps_irq0.
#
# Clocks: pl_clk0 (100 MHz) into an MMCM: VCO 1066.67 MHz (M 32, D 3), core_clk / 8 = 133.33 MHz,
# core_clk2x / 4 = 266.67 MHz (the TMEM's pumped RAMs: both from one VCO by integer dividers, no
# phase shift, so core_clk2x rises with core_clk), xclk / 6 = 177.78 MHz (the PS's AXI ports, the
# CDMA, otpu_mem_ch's host side). The MIG's ui_clk (266.5 MHz, from the SODIMM's oscillator) is
# both channels' controller side and the merge's clock.
#
# Variables (set before sourcing): CORE_MHZ (133.33 only: the MMCM above), CLK2X,
# otpu_tpu_params (a dict NAME value of otpu_zbd_tpu's parameters, create_project.tcl's; absent:
# the module's defaults, the target's), IP_DIR (where otpu_ddr4 is made if the project has none).

proc ip_vlnv {name} {
  set defs [lsort -decreasing [get_ipdefs -all "xilinx.com:ip:${name}:*"]]
  if {[llength $defs] == 0} { error "IP $name not found in this Vivado installation" }
  return [lindex $defs 0]
}

if {![info exists CORE_MHZ]} { set CORE_MHZ 133.33 }
if {![info exists CLK2X]} { set CLK2X 1 }
if {abs($CORE_MHZ - 133.33) > 0.01} {
  error "bd_zcu104.tcl: CORE_MHZ $CORE_MHZ: the ZCU104's MMCM makes 133.33 MHz (128 B a cycle = DDR4-2133 x 64)"
}
set VCO_M 32
set VCO_D 3
set VCO [expr {100.0 * $VCO_M / $VCO_D}]
set CORE_DIV 8
set X_DIV 6
set CORE_HZ [expr {int(floor($VCO * 1.0e6 / $CORE_DIV))}]
set CLK2X_HZ [expr {int(floor($VCO * 1.0e6 / ($CORE_DIV / 2)))}]
set X_HZ [expr {int(floor($VCO * 1.0e6 / $X_DIV))}]
puts "core_clk [expr {$CORE_HZ / 1e6}] MHz, core_clk2x [expr {$CLK2X_HZ / 1e6}] MHz, xclk [expr {$X_HZ / 1e6}] MHz (VCO $VCO MHz)"

# the MIG, which the ddr4 cell instantiates (create_project.tcl makes it first; FuseSoC here)
if {[get_ips -quiet otpu_ddr4] eq ""} {
  otpu_create_mig [expr {[info exists IP_DIR] ? $IP_DIR : [file normalize ./ip]}]
  update_compile_order -fileset sources_1
}

create_bd_design otpu_zbd
current_bd_design otpu_zbd

# ------------------------------------------------------------------ external ports
create_bd_port -dir I -type rst cpu_reset
set_property CONFIG.POLARITY ACTIVE_HIGH [get_bd_ports cpu_reset]
create_bd_port -dir O -from 3 -to 0 led

# ------------------------------------------------------------------ the PS (the board's preset)
set ps [create_bd_cell -type ip -vlnv [ip_vlnv zynq_ultra_ps_e] ps]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0 {1} CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} CONFIG.PSU__USE__M_AXI_GP2 {0} \
  CONFIG.PSU__USE__S_AXI_GP2 {1} CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
  CONFIG.PSU__USE__IRQ0 {1} \
] $ps
set pl0 [get_property CONFIG.PSU__CRL_APB__PL0_REF_CTRL__ACT_FREQMHZ $ps]
puts "pl_clk0: $pl0 MHz"

# ------------------------------------------------------------------ clocks and resets
set clk [create_bd_cell -type ip -vlnv [ip_vlnv clk_wiz] clk_wiz_0]
set_property -dict [list \
  CONFIG.PRIM_IN_FREQ {100.000} CONFIG.PRIM_SOURCE {Global_buffer} \
  CONFIG.USE_RESET {false} CONFIG.USE_LOCKED {true} CONFIG.NUM_OUT_CLKS {3} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {133.333} CONFIG.CLK_OUT1_PORT {core_clk} \
  CONFIG.CLKOUT2_USED {true} CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {266.667} \
  CONFIG.CLKOUT2_REQUESTED_PHASE {0.000} CONFIG.CLK_OUT2_PORT {core_clk2x} \
  CONFIG.CLKOUT3_USED {true} CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {177.778} CONFIG.CLK_OUT3_PORT {xclk} \
] $clk
set_property -dict [list CONFIG.OVERRIDE_MMCM {true} CONFIG.MMCM_DIVCLK_DIVIDE $VCO_D \
  CONFIG.MMCM_CLKFBOUT_MULT_F [format %.3f $VCO_M] CONFIG.MMCM_CLKOUT0_DIVIDE_F [format %.3f $CORE_DIV] \
  CONFIG.MMCM_CLKOUT1_DIVIDE [expr {$CORE_DIV / 2}] CONFIG.MMCM_CLKOUT2_DIVIDE $X_DIV] $clk
connect_bd_net [get_bd_pins ps/pl_clk0] [get_bd_pins clk_wiz_0/clk_in1]
foreach {pin hz} [list core_clk $CORE_HZ core_clk2x $CLK2X_HZ xclk $X_HZ] {
  set f [get_property CONFIG.FREQ_HZ [get_bd_pins clk_wiz_0/$pin]]
  if {abs($f - $hz) > 1000} { error "bd_zcu104.tcl: the clock wizard makes $pin at $f Hz, not $hz" }
  puts "$pin: $f Hz"
}
set CORE_HZ [get_property CONFIG.FREQ_HZ [get_bd_pins clk_wiz_0/core_clk]]
set X_HZ [get_property CONFIG.FREQ_HZ [get_bd_pins clk_wiz_0/xclk]]

# core reset: until the MMCM locks, and while the PS holds the fabric in reset (pl_resetn0)
foreach {r c} {rst_core core_clk rst_x xclk} {
  create_bd_cell -type ip -vlnv [ip_vlnv proc_sys_reset] $r
  connect_bd_net [get_bd_pins clk_wiz_0/$c] [get_bd_pins $r/slowest_sync_clk]
  connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins $r/dcm_locked]
  connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins $r/ext_reset_in]
}

# the PS's AXI ports in xclk
connect_bd_net [get_bd_pins clk_wiz_0/xclk] [get_bd_pins ps/maxihpm0_fpd_aclk] [get_bd_pins ps/saxihp0_fpd_aclk]

# ------------------------------------------------------------------ the accelerator, the merge
# and the SODIMM's controller (RTL module references)
set tpu [create_bd_cell -type module -reference otpu_zbd_tpu tpu]
if {[info exists otpu_tpu_params]} {
  set cfg {}
  dict for {k v} $otpu_tpu_params { lappend cfg CONFIG.$k $v }
  set_property -dict $cfg $tpu
  # read back: a parameter the module does not have, or a value the cell did not take, stops here
  dict for {k v} $otpu_tpu_params {
    set got [get_property CONFIG.$k $tpu]
    if {[string is integer -strict $v] ? $got != $v : ![string equal -nocase $got $v]} {
      error "bd_zcu104.tcl: tpu CONFIG.$k is '$got', expected '$v'"
    }
  }
  puts "tpu: [llength [dict keys $otpu_tpu_params]] parameters set"
}
create_bd_cell -type module -reference otpu_zbd_mux merge
create_bd_cell -type module -reference otpu_zbd_ddr4 ddr4

connect_bd_net [get_bd_pins clk_wiz_0/core_clk] [get_bd_pins tpu/clk]
connect_bd_net [get_bd_pins clk_wiz_0/core_clk2x] [get_bd_pins tpu/clk_f]
connect_bd_net [get_bd_pins clk_wiz_0/xclk] [get_bd_pins tpu/xclk]
connect_bd_net [get_bd_pins rst_core/peripheral_aresetn] [get_bd_pins tpu/core_rstn]
connect_bd_net [get_bd_pins rst_x/peripheral_aresetn] [get_bd_pins tpu/xresetn]
connect_bd_net [get_bd_pins ddr4/ui_clk] [get_bd_pins tpu/uclk] [get_bd_pins merge/clk]
connect_bd_net [get_bd_pins ddr4/ui_rst] [get_bd_pins tpu/urst] [get_bd_pins merge/rst]
connect_bd_net [get_bd_pins ddr4/calib_done] [get_bd_pins tpu/calib_done]
connect_bd_net [get_bd_pins merge/err] [get_bd_pins tpu/mux_err]
connect_bd_net [get_bd_pins tpu/led] [get_bd_ports led]
connect_bd_net [get_bd_ports cpu_reset] [get_bd_pins ddr4/sys_rst]
# the channels' controller ports, tpu -> merge, and the MIG's user interface, merge -> ddr4
foreach p {cmd_valid cmd_ready cmd_we cmd_addr wdata_valid wdata_ready wdata_data wdata_we
           rdata_valid rdata_data} {
  connect_bd_net [get_bd_pins tpu/c_$p] [get_bd_pins merge/c_$p]
}
foreach p {addr cmd en hi_pri rdy wdf_data wdf_mask wdf_wren wdf_end wdf_rdy rd_data
           rd_data_valid} {
  connect_bd_net [get_bd_pins merge/app_$p] [get_bd_pins ddr4/app_$p]
}
# the SODIMM and its reference clock: external (the MIG's board-flow constraints place them)
foreach i {C0_DDR4 C0_SYS_CLK} {
  make_bd_intf_pins_external [get_bd_intf_pins ddr4/$i]
  set_property NAME $i [get_bd_intf_ports -of [get_bd_intf_nets -of [get_bd_intf_pins ddr4/$i]]]
}

# ------------------------------------------------------------------ the host's copies: AXI CDMA
set cdma [create_bd_cell -type ip -vlnv [ip_vlnv axi_cdma] cdma]
set_property -dict [list CONFIG.C_INCLUDE_SG {0} CONFIG.C_INCLUDE_DRE {0} \
  CONFIG.C_M_AXI_DATA_WIDTH {128} CONFIG.C_M_AXI_MAX_BURST_LEN {256} \
  CONFIG.C_ADDR_WIDTH {40} CONFIG.C_USE_DATAMOVER_LITE {0}] $cdma
connect_bd_net [get_bd_pins clk_wiz_0/xclk] [get_bd_pins cdma/m_axi_aclk] [get_bd_pins cdma/s_axi_lite_aclk]
connect_bd_net [get_bd_pins rst_x/peripheral_aresetn] [get_bd_pins cdma/s_axi_lite_aresetn]
connect_bd_net [get_bd_pins cdma/cdma_introut] [get_bd_pins ps/pl_ps_irq0]

set scd [create_bd_cell -type ip -vlnv [ip_vlnv smartconnect] sc_dma]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2} CONFIG.NUM_CLKS {1}] $scd
connect_bd_net [get_bd_pins clk_wiz_0/xclk] [get_bd_pins sc_dma/aclk]
connect_bd_net [get_bd_pins rst_x/interconnect_aresetn] [get_bd_pins sc_dma/aresetn]
connect_bd_intf_net [get_bd_intf_pins cdma/M_AXI] [get_bd_intf_pins sc_dma/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_dma/M00_AXI] [get_bd_intf_pins ps/S_AXI_HP0_FPD]
connect_bd_intf_net [get_bd_intf_pins sc_dma/M01_AXI] [get_bd_intf_pins tpu/s_axi_dma]

# ------------------------------------------------------------------ SYSMONE4 (die temperature)
# its 10-bit code: UG580, T = code * 509.3140064 / 1024 - 280.23087870 (internal reference); the
# host takes the formula from CFG_PLATFORM's family (opentpu/host/regs.py temp_c), as the BCU1525's
set sysmon [create_bd_cell -type ip -vlnv [ip_vlnv system_management_wiz] sysmon]
set_property -dict [list CONFIG.INTERFACE_SELECTION {Enable_AXI} \
  CONFIG.DCLK_FREQUENCY [expr {int(ceil($CORE_HZ / 1.0e6))}] \
  CONFIG.SEQUENCER_MODE {Default} CONFIG.CHANNEL_ENABLE_VP_VN {false} \
  CONFIG.ENABLE_TEMP_BUS {true} CONFIG.OT_ALARM {false} CONFIG.USER_TEMP_ALARM {false} \
  CONFIG.VCCINT_ALARM {false} CONFIG.VCCAUX_ALARM {false}] $sysmon
connect_bd_net [get_bd_pins clk_wiz_0/core_clk] [get_bd_pins sysmon/s_axi_aclk]
connect_bd_net [get_bd_pins rst_core/peripheral_aresetn] [get_bd_pins sysmon/s_axi_aresetn]
connect_bd_net [get_bd_pins sysmon/temp_out] [get_bd_pins tpu/device_temp]

# ------------------------------------------------------------------ control interconnect
set scl [create_bd_cell -type ip -vlnv [ip_vlnv smartconnect] sc_ctl]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {3} CONFIG.NUM_CLKS {2}] $scl
connect_bd_net [get_bd_pins clk_wiz_0/xclk] [get_bd_pins sc_ctl/aclk]
connect_bd_net [get_bd_pins clk_wiz_0/core_clk] [get_bd_pins sc_ctl/aclk1]
connect_bd_net [get_bd_pins rst_x/interconnect_aresetn] [get_bd_pins sc_ctl/aresetn]
connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_FPD] [get_bd_intf_pins sc_ctl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_ctl/M00_AXI] [get_bd_intf_pins tpu/s_axi_ctl]
connect_bd_intf_net [get_bd_intf_pins sc_ctl/M01_AXI] [get_bd_intf_pins cdma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins sc_ctl/M02_AXI] [get_bd_intf_pins sysmon/S_AXI_LITE]

# ------------------------------------------------------------------ address map
set hpm [get_bd_addr_spaces ps/Data]
assign_bd_address -offset 0xA0000000 -range 64K -target_address_space $hpm \
  [get_bd_addr_segs -of [get_bd_intf_pins tpu/s_axi_ctl]] -force
assign_bd_address -offset 0xA0020000 -range 64K -target_address_space $hpm \
  [get_bd_addr_segs -of [get_bd_intf_pins cdma/S_AXI_LITE]] -force
assign_bd_address -offset 0xA0030000 -range 64K -target_address_space $hpm \
  [get_bd_addr_segs -of [get_bd_intf_pins sysmon/S_AXI_LITE]] -force
set cds [get_bd_addr_spaces cdma/Data]
assign_bd_address -offset 0x1000000000 -range 4G -target_address_space $cds \
  [get_bd_addr_segs -of [get_bd_intf_pins tpu/s_axi_dma]] -force
# the PS DDR (the 2 GiB below 0x8000_0000) for the CDMA; the PS's other windows stay unmapped
set ddrlo [get_bd_addr_segs -quiet ps/SAXIGP2/HP0_DDR_LOW]
if {$ddrlo eq ""} { error "bd_zcu104.tcl: no HP0_DDR_LOW segment on S_AXI_HP0_FPD: [get_bd_addr_segs ps/SAXIGP2/*]" }
assign_bd_address -offset 0x00000000 -range 2G -target_address_space $cds $ddrlo -force

regenerate_bd_layout
validate_bd_design

foreach p {C0_DDR4 C0_SYS_CLK} {
  if {[get_bd_intf_ports $p] eq ""} { error "block design port $p missing: [get_bd_intf_ports]" }
}
# the CDMA's side of otpu_mem_ch: no IDs (it answers in order), the 37-bit window
foreach {k want} {ID_WIDTH 0 ADDR_WIDTH 37} {
  set got [get_property CONFIG.$k [get_bd_intf_pins sc_dma/M01_AXI]]
  if {$got != $want} { error "sc_dma/M01_AXI (tpu/s_axi_dma): $k $got, expected $want" }
}
# the SODIMM as the block design (and the .xsa) describes it is the MIG's: otpu_zbd_ddr4.v's
# interface parameters against otpu_ddr4's settings
set mig [get_ips otpu_ddr4]
foreach {k ipk} {TIMEPERIOD_PS C0.DDR4_TimePeriod DATA_WIDTH C0.DDR4_DataWidth
                 MEMORY_TYPE C0.DDR4_MemoryType MEMORY_PART C0.DDR4_MemoryPart
                 CAS_LATENCY C0.DDR4_CasLatency CAS_WRITE_LATENCY C0.DDR4_CasWriteLatency} {
  set want [get_property CONFIG.$ipk $mig]
  foreach o [list [get_bd_intf_pins ddr4/C0_DDR4] [get_bd_intf_ports C0_DDR4]] {
    set got [get_property CONFIG.$k $o]
    if {![string equal -nocase $got $want]} {
      error "$o: $k is '$got', the MIG's $ipk is '$want' (otpu_zbd_ddr4.v's X_INTERFACE_PARAMETER)"
    }
  }
}
foreach {cell want} {rst_core 0 rst_x 0} {
  set got [get_property CONFIG.C_EXT_RESET_HIGH [get_bd_cells $cell]]
  if {$got != $want} { error "$cell: C_EXT_RESET_HIGH is $got, expected $want" }
}
foreach sp [list $hpm $cds] {
  foreach s [get_bd_addr_segs -quiet -of_objects $sp] {
    puts "address map [get_property NAME $sp]: [get_property OFFSET $s] [get_property RANGE $s] $s"
  }
}
save_bd_design
# Global synthesis: every cell of the block design in the top's synthesis run (synth_1), not each
# in its own out-of-context run, so the module references (tpu, merge, ddr4) build as the RTL top
# built them: with the project's SYNTHESIS define, act_uram.xdc's UltraRAM placement and
# synth_1's strategy (retiming). The AMD IP here (PS, clocking wizard, resets, SmartConnects,
# CDMA, SYSMON) then synthesizes with that strategy too: the same configuration, a somewhat
# different netlist (about 1,600 more LUTs than out of context). Vivado keeps each module
# reference a soft hierarchy (KEEP_HIERARCHY SOFT). The MIG otpu_ddr4 is a project IP of its
# own, still out of context (build.tcl).
set_property synth_checkpoint_mode None [get_files otpu_zbd.bd]
