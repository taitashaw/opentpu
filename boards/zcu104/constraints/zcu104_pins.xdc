# ZCU104 (xczu7ev-ffvc1156-2-e): the top's board pins (otpu_fpga_top_zcu104). Locations and
# standards from AMD's ZCU104 board file in Vivado (XilinxBoardStore zcu104/1.1 part0_pins.xml): CPU_RESET M11,
# GPIO_LED_0..3_LS D5 D6 A5 B5, all LVCMOS33 in bank 88. The SODIMM's pins and its 300 MHz
# reference (CLK_300_P/N AH18/AH17) are the MIG's: its board-flow constraints place them.

set_property -dict {PACKAGE_PIN M11 IOSTANDARD LVCMOS33} [get_ports cpu_reset]
set_property -dict {PACKAGE_PIN D5 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN D6 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN A5 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN B5 IOSTANDARD LVCMOS33} [get_ports {led[3]}]

# the push button is asynchronous (the MIG synchronizes its sys_rst); the LEDs are for people
set_false_path -from [get_ports cpu_reset]
set_false_path -to [get_ports {led[*]}]
# the SODIMM's RESET# (the MIG holds it through power-up and calibration; PG150 leaves it untimed)
set_false_path -to [get_ports c0_ddr4_reset_n]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
