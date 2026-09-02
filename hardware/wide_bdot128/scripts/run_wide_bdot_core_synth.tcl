if { $argc != 1 } {
    puts "Usage: vivado -mode batch -source run_wide_bdot_core_synth.tcl -tclargs <build_dir>"
    exit 2
}

set build_dir [file normalize [lindex $argv 0]]
set report_dir [file join $build_dir reports]
set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
set rtl_dir [file join $project_root src rtl]
file mkdir $build_dir
file mkdir $report_dir

create_project wide_bdot_core $build_dir -part xczu3eg-sbva484-1-e -force
source [file join $script_dir wide_bram_ip_config.tcl]
configure_wide_bram activation_bram_32x128 8192
configure_wide_bram weight_bram_400k_32x128 102400

set baseline_rtl [file normalize [file join $project_root .. 260726_XPC32_RegToReg src rtl]]
add_files -norecurse [list \
    [file join $baseline_rtl basic_modules.v] \
    [file join $baseline_rtl xnor_popcount32.v] \
    [file join $rtl_dir bdot_cpu_control.v] \
    [file join $rtl_dir reset_sync.v] \
    [file join $rtl_dir wide_xnor_popcount.v] \
    [file join $rtl_dir wide_bdot_accel.v] \
    [file join $rtl_dir rv32i_cpu.v] \
    [file join $rtl_dir wide_bram_bmg_wrapper.v] \
    [file join $rtl_dir wide_bdot_fpga_core.v] \
]
add_files -fileset constrs_1 -norecurse [file join $project_root vivado wide_bdot_core.xdc]
set_property top wide_bdot_fpga_core [current_fileset]
update_compile_order -fileset sources_1

foreach ip [get_ips] {
    synth_ip $ip
}

synth_design -top wide_bdot_fpga_core -part xczu3eg-sbva484-1-e \
    -mode out_of_context -flatten_hierarchy rebuilt
report_utilization -file [file join $report_dir post_synth_utilization.rpt]
report_timing_summary -delay_type min_max -max_paths 20 \
    -file [file join $report_dir post_synth_timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -sort_by group \
    -file [file join $report_dir post_synth_timing_paths.rpt]
report_cdc -details -file [file join $report_dir post_synth_cdc.rpt]
write_checkpoint -force [file join $build_dir wide_bdot_fpga_core_synth.dcp]

set status_file [open [file join $report_dir build_status.txt] w]
puts $status_file "status=PASS"
puts $status_file "part=[get_property PART [current_project]]"
puts $status_file "top=wide_bdot_fpga_core"
close $status_file

puts "WIDE BDOT CORE SYNTH PASS: reports=$report_dir"
exit 0
