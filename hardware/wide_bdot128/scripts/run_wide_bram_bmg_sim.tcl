if { $argc != 1 } {
    puts "Usage: vivado -mode batch -source run_wide_bram_bmg_sim.tcl -tclargs <build_dir>"
    exit 2
}

set build_dir [file normalize [lindex $argv 0]]
set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
file mkdir $build_dir

create_project wide_bram_bmg_sim $build_dir -part xczu3eg-sbva484-1-e -force
source [file join $script_dir wide_bram_ip_config.tcl]
configure_wide_bram activation_bram_32x128 8192
configure_wide_bram weight_bram_400k_32x128 102400

add_files -norecurse [file join $project_root src rtl wide_bram_bmg_wrapper.v]
add_files -fileset sim_1 -norecurse \
    [file join $project_root testbench wide_bram_bmg_equivalence_tb.v]
set_property top wide_bram_bmg_equivalence_tb [get_filesets sim_1]
set_property xsim.elaborate.debug_level off [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation -simset sim_1 -mode behavioral
close_sim
puts "BMG EQUIVALENCE SIM PASS"
exit 0
