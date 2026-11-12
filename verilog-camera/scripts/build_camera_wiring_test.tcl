set workspace [file dirname [file dirname [file normalize [info script]]]]
set build_dir [file join $workspace build camera_wiring_test]
set reports_dir [file join $workspace reports camera_wiring_test]
file mkdir $build_dir $reports_dir
set validated_file [file join $reports_dir validated_bitstream.txt]
if {[file exists $validated_file]} {file delete $validated_file}
create_project -in_memory -part xc7a35tcpg236-1
read_verilog [file join $workspace rtl basys3_camera_clock.v]
read_verilog [file join $workspace rtl basys3_camera_wiring_test_top.v]
read_xdc [file join $workspace constraints basys3_camera_wiring_test.xdc]
synth_design -top basys3_camera_wiring_test_top -part xc7a35tcpg236-1
opt_design
place_design
route_design
set timing_text [report_timing_summary -delay_type min_max -report_unconstrained -return_string]
set f [open [file join $reports_dir timing.rpt] w]
puts $f $timing_text
close $f
if {![string match {*All user specified timing constraints are met.*} $timing_text]} {
    error "Wiring test failed routed timing."
}
foreach kind {max min} {
    set worst [get_timing_paths -delay_type $kind -max_paths 1 -nworst 1]
    if {![llength $worst] || [get_property SLACK $worst] < 0} {error "$kind timing failed"}
}
report_drc -file [file join $reports_dir drc.rpt]
set violations [get_drc_violations -quiet]
if {[llength $violations]} {error "Wiring test has DRC violations: $violations"}
report_io -file [file join $reports_dir io.rpt]
set bitstream [file normalize [file join $build_dir basys3_camera_wiring_test_top.bit]]
write_bitstream -force $bitstream
set f [open $validated_file w]
puts $f [list $bitstream [file size $bitstream] [file mtime $bitstream]]
close $f
puts "CAMERA_WIRING_TEST_BUILD_OK=$bitstream"
close_project
