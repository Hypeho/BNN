if { $argc != 1 } {
    puts "Usage: vivado -mode batch -source run_wide_bdot_core_route.tcl -tclargs <build_dir>"
    exit 2
}

set build_dir [file normalize [lindex $argv 0]]
set report_dir [file join $build_dir reports]
set synth_dcp [file join $build_dir wide_bdot_fpga_core_synth.dcp]
if { ![file exists $synth_dcp] } {
    puts "ERROR: synthesized checkpoint not found: $synth_dcp"
    exit 3
}

open_checkpoint $synth_dcp

# OOC clock source locations are only for realistic clock-delay estimation.
# The board-level Block Design will replace them with its actual clock buffers.
set bufg_sites [lsort [get_sites -quiet -filter {SITE_TYPE == BUFGCE}]]
if { [llength $bufg_sites] >= 2 } {
    set_property HD.CLK_SRC [lindex $bufg_sites 0] [get_ports cpu_clk]
    set_property HD.CLK_SRC [lindex $bufg_sites 1] [get_ports bram_clk]
}

opt_design
place_design
phys_opt_design
route_design

report_route_status -file [file join $report_dir post_route_status.rpt]
report_utilization -file [file join $report_dir post_route_utilization.rpt]
report_timing_summary -delay_type min_max -max_paths 20 \
    -file [file join $report_dir post_route_timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -sort_by group \
    -file [file join $report_dir post_route_timing_paths.rpt]
report_cdc -details -file [file join $report_dir post_route_cdc.rpt]
report_power -file [file join $report_dir post_route_power.rpt]
write_checkpoint -force [file join $build_dir wide_bdot_fpga_core_routed.dcp]

set worst_setup_path [get_timing_paths -quiet -delay_type max -max_paths 1]
set worst_hold_path [get_timing_paths -quiet -delay_type min -max_paths 1]
set worst_setup_slack [get_property SLACK $worst_setup_path]
set worst_hold_slack [get_property SLACK $worst_hold_path]
set timing_pass [expr {$worst_setup_slack >= 0.0 && $worst_hold_slack >= 0.0}]

set status_file [open [file join $report_dir route_status.txt] w]
puts $status_file [expr {$timing_pass ? "status=PASS" : "status=FAIL"}]
puts $status_file "top=wide_bdot_fpga_core"
puts $status_file "worst_setup_slack_ns=$worst_setup_slack"
puts $status_file "worst_hold_slack_ns=$worst_hold_slack"
close $status_file

if { !$timing_pass } {
    puts "ERROR: WIDE BDOT CORE TIMING FAIL: setup=$worst_setup_slack ns hold=$worst_hold_slack ns"
    exit 4
}

puts "WIDE BDOT CORE ROUTE PASS: reports=$report_dir"
exit 0
