set script_dir [file dirname [file normalize [info script]]]
set workspace [file dirname $script_dir]
set upstream [file normalize [file join $workspace .. repos neural-net-on-fpga hdl]]
set project_dir [file join $workspace build camera_test_basys3]
set project_file [file join $project_dir camera_test_basys3.xpr]
set reports_dir [file join $workspace reports camera_test]
file mkdir $reports_dir
if {[current_project -quiet] ne ""} {
    if {[file normalize [get_property DIRECTORY [current_project]]] ne [file normalize $project_dir]} {
        error "Save and close the other project before opening the camera project."
    }
} elseif {[file exists $project_file]} {
    open_project $project_file
} else {
    create_project camera_test_basys3 $project_dir -part xc7a35tcpg236-1
    set_property target_language Verilog [current_project]
    set_property simulator_language Mixed [current_project]
}
set sources [list \
    [file join $workspace rtl basys3_camera_test_top.v] \
    [file join $workspace rtl basys3_camera_clock.v] \
    [file join $workspace rtl ov7670_config.v] \
    [file join $workspace rtl ov7670_capture.v] \
    [file join $workspace rtl camera_vga.v] \
    [file normalize [file join $workspace .. verilog-uart rtl uart_tx.v]]]
foreach f $sources {
    if {![file isfile $f]} {error "Missing camera project source: $f"}
    if {![llength [get_files -quiet $f]]} {add_files -norecurse $f}
}
set xdc [file join $workspace constraints basys3_camera_test.xdc]
if {![llength [get_files -quiet $xdc]]} {add_files -fileset constrs_1 $xdc}
set_property top basys3_camera_test_top [get_filesets sources_1]
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY rebuilt [get_runs synth_1]
update_compile_order -fileset sources_1
puts "CAMERA_PROJECT=$project_file"
