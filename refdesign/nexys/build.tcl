# SPDX-License-Identifier: GPL-2.0-only
if {[llength $argv] != 5} {
  error "Usage: build.tcl <core-root> <output> <mig.prj> <generate|build> <jobs>"
}
lassign $argv root out mig_input action jobs
set here [file dirname [file normalize [info script]]]
set_param general.maxThreads $jobs
create_project nexys $out/project -part xc7a200tsbg484-1
foreach unit {pkg reset fifo plane_bounds color reader raster row_stats scanout tmds_encoder tmds_lane_7series tmds_7series hdmi_7series} {
  add_files -norecurse $root/hdl/ironvideo_$unit.sv
}
add_files -norecurse $root/hdl/ironvideo_top.v
add_files -norecurse $here/clocks.v
update_compile_order -fileset sources_1

proc ip {name type} {
  create_bd_cell -type ip -vlnv [lindex [get_ipdefs xilinx.com:ip:$type:*] 0] $name
}
proc net {args} {
  set pins {}
  foreach name $args {
    set pin [get_bd_pins -quiet $name]
    if {![llength $pin]} {set pin [get_bd_ports $name]}
    lappend pins $pin
  }
  connect_bd_net {*}$pins
}
proc bus {a b} {connect_bd_intf_net [get_bd_intf_pins $a] [get_bd_intf_pins $b]}
proc port {name dir pin {width 1} {hz 0}} {
  if {$hz} {
    create_bd_port -dir $dir -type clk -freq_hz $hz $name
  } elseif {$width > 1} {
    create_bd_port -dir $dir -from [expr {$width-1}] -to 0 $name
  } else {
    create_bd_port -dir $dir $name
  }
  net $name $pin
}

create_bd_design system
create_bd_cell -type module -reference nexys_reference_clocks clocks
port sys_clock I clocks/sys_clock 1 100000000
port resetn I clocks/resetn

set file [open $mig_input r]
set xml [read $file]
close $file
foreach {old new} {
  {<SystemClock>Single-Ended</SystemClock>} {<SystemClock>No Buffer</SystemClock>}
  {<C0_S_AXI_DATA_WIDTH>32</C0_S_AXI_DATA_WIDTH>} {<C0_S_AXI_DATA_WIDTH>128</C0_S_AXI_DATA_WIDTH>}
} {
  if {[regexp -all -- $old $xml] != 1} {error "Unexpected pinned MIG project: $old"}
  set xml [string map [list $old $new] $xml]
}
set file [open $out/mig-generated.prj w]
puts -nonewline $file $xml
close $file
ip ddr mig_7series
set_property CONFIG.XML_INPUT_FILE $out/mig-generated.prj [get_bd_cells ddr]
make_bd_intf_pins_external [get_bd_intf_pins ddr/DDR3]
net clocks/mig_sys ddr/sys_clk_i
net clocks/ref_clk ddr/clk_ref_i
net resetn ddr/sys_rst
net ddr/init_calib_complete clocks/ddr_ready
ip ddr_reset proc_sys_reset
net ddr/ui_clk ddr_reset/slowest_sync_clk
net ddr/ui_clk_sync_rst ddr_reset/ext_reset_in
net clocks/ddr_clock_locked ddr_reset/dcm_locked
net ddr_reset/peripheral_aresetn ddr/aresetn

ip cpu microblaze
set_property -dict [list CONFIG.C_ENDIANNESS 1 CONFIG.C_USE_MMU 0 \
    CONFIG.C_USE_ICACHE 0 CONFIG.C_USE_DCACHE 0 CONFIG.C_D_AXI 1 \
    CONFIG.C_USE_BARREL 1 CONFIG.C_USE_DIV 1 CONFIG.C_USE_HW_MUL 2 \
    CONFIG.C_USE_MSR_INSTR 1 CONFIG.C_USE_INTERRUPT 0 CONFIG.C_DEBUG_ENABLED 1] [get_bd_cells cpu]
apply_bd_automation -rule xilinx.com:bd_rule:microblaze \
    -config {local_mem "64KB" ecc "None" cache "None" debug_module "Debug Only" axi_periph "Disabled" axi_intc "0" clk "/clocks/sys (80 MHz)"} \
    [get_bd_cells cpu]
set reset_cell [lindex [get_bd_cells -filter {VLNV =~ "xilinx.com:ip:proc_sys_reset:*" && NAME != ddr_reset}] 0]
if {$reset_cell eq ""} {error "Missing CPU reset controller"}
foreach pin {dcm_locked ext_reset_in} {
  set old [get_bd_nets -of_objects [get_bd_pins $reset_cell/$pin]]
  if {[llength $old]} {disconnect_bd_net $old [get_bd_pins $reset_cell/$pin]}
}
net clocks/ready $reset_cell/dcm_locked
net resetn $reset_cell/ext_reset_in

ip fabric smartconnect
set_property -dict [list CONFIG.NUM_SI 2 CONFIG.NUM_MI 3 CONFIG.NUM_CLKS 2] [get_bd_cells fabric]
set_property CONFIG.ADVANCED_PROPERTIES {__view__ {functional {S01_Entry {PRIORITY_ARB 1}}}} [get_bd_cells fabric]
net clocks/sys fabric/aclk
net ddr/ui_clk fabric/aclk1
net $reset_cell/peripheral_aresetn fabric/aresetn
bus cpu/M_AXI_DP fabric/S00_AXI
bus fabric/M00_AXI ddr/S_AXI

ip uart axi_uartlite
set_property CONFIG.C_BAUDRATE 115200 [get_bd_cells uart]
net clocks/sys uart/s_axi_aclk
net $reset_cell/peripheral_aresetn uart/s_axi_aresetn
bus fabric/M01_AXI uart/S_AXI
port uart_rx I uart/rx
port uart_tx O uart/tx

create_bd_cell -type module -reference ironvideo_top ironvideo
set_property -dict [list CONFIG.FAMILY 7SERIES CONFIG.DATA_WIDTH 128 CONFIG.MAX_BURST 32 \
    CONFIG.FIFO_KIB 16 CONFIG.ARQOS 15 CONFIG.AXI_ID_WIDTH 1 CONFIG.FORMAT_MASK 15] [get_bd_cells ironvideo]
net clocks/sys ironvideo/axi_clk
net clocks/pixel ironvideo/pixel_clk
net clocks/serial ironvideo/serial_clk
net $reset_cell/peripheral_aresetn ironvideo/reset_n
bus ironvideo/M_AXI fabric/S01_AXI
bus fabric/M02_AXI ironvideo/S_AXI
foreach {name pin width} {
  hdmi_clk_p tmds_clk_p 1 hdmi_clk_n tmds_clk_n 1 hdmi_data_p tmds_data_p 3 hdmi_data_n tmds_data_n 3
} {port $name O ironvideo/$pin $width}

set video_space [get_bd_addr_spaces ironvideo/M_AXI]
set cpu_space [get_bd_addr_spaces cpu/Data]
if {[llength $cpu_space] != 1} {error "Missing MicroBlaze data address space"}
set ddr_segment [get_bd_addr_segs ddr/memmap/memaddr]
foreach space [list $cpu_space $video_space] {
  assign_bd_address -offset 0x80000000 -range 512M -target_address_space $space $ddr_segment -force
}
foreach {iface address} {uart/S_AXI 0x40600000 ironvideo/S_AXI 0x43000000} {
  set segment [get_bd_addr_segs -of_objects [get_bd_intf_pins $iface]]
  if {[llength $segment] != 1} {error "Expected one control segment: $iface"}
  assign_bd_address -offset $address -range 64K -target_address_space $cpu_space $segment -force
  exclude_bd_addr_seg -offset $address -range 64K -target_address_space $video_space $segment
}
validate_bd_design
save_bd_design
write_bd_tcl -force $out/system.generated.tcl
generate_target all [get_files system.bd]
set wrapper [make_wrapper -files [get_files system.bd] -top]
add_files -norecurse $wrapper
set_property top system_wrapper [current_fileset]
add_files -fileset constrs_1 $here/board.xdc
add_files -fileset constrs_1 $here/interface_timing.xdc
set_property USED_IN_SYNTHESIS false [get_files $here/interface_timing.xdc]
update_compile_order -fileset sources_1
if {$action eq "generate"} {
  puts "NEXYS REFERENCE BLOCK DESIGN PASS"
  exit
}

set_property STEPS.OPT_DESIGN.TCL.PRE $here/video_cdc.tcl [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "Nexys reference route failed"}
open_run impl_1
set impl [get_property DIRECTORY [get_runs impl_1]]
source $here/qualify.tcl
file copy $impl/system_wrapper.bit $out/fpga.bit
write_mem_info -force $out/fpga.mmi
puts "NEXYS REFERENCE ROUTE PASS"
