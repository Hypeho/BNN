if { $argc != 1 } {
    puts "Usage: vivado -mode batch -source create_wide_bram_ips.tcl -tclargs <build_dir>"
    exit 2
}

set build_dir [file normalize [lindex $argv 0]]
set report_dir [file join $build_dir reports]
file mkdir $build_dir
file mkdir $report_dir

create_project wide_bram_ip $build_dir -part xczu3eg-sbva484-1-e -force
set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir wide_bram_ip_config.tcl]

configure_wide_bram activation_bram_32x128 8192
configure_wide_bram weight_bram_32x128 131072
configure_wide_bram weight_bram_384k_32x128 98304
configure_wide_bram weight_bram_400k_32x128 102400

foreach ip [get_ips] {
    create_ip_run $ip
}
set ip_runs [get_runs -quiet *_synth_1]
launch_runs $ip_runs -jobs 2
foreach run $ip_runs {
    wait_on_run $run
    if { ![string match "*Complete*" [get_property STATUS $run]] } {
        puts "ERROR: IP synthesis failed: $run"
        exit 3
    }
}

set config_file [open [file join $report_dir ip_configuration.txt] w]
foreach ip [get_ips] {
    puts $config_file "\[$ip\]"
    foreach property [lsort [list_property $ip]] {
        if { [string match "CONFIG.*" $property] } {
            puts $config_file "$property=[get_property $property $ip]"
        }
    }
}
close $config_file

foreach run $ip_runs {
    set run_dir [get_property DIRECTORY $run]
    set reports [glob -nocomplain [file join $run_dir *_utilization_synth.rpt]]
    if { [llength $reports] != 1 } {
        puts "ERROR: expected one utilization report for $run"
        exit 4
    }
    file copy -force [lindex $reports 0] \
        [file join $report_dir ${run}_utilization.rpt]
}

set status_file [open [file join $report_dir build_status.txt] w]
puts $status_file "part=[get_property PART [current_project]]"
foreach run $ip_runs {
    puts $status_file "$run=[get_property STATUS $run]"
}
close $status_file

puts "BMG IP BUILD PASS: reports=$report_dir"
exit 0
