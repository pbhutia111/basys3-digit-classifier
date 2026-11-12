source [file join [file dirname [file normalize [info script]]] create_camera_test.tcl]
set validated_file [file join $reports_dir validated_bitstream.txt]
if {[file exists $validated_file]} {file delete $validated_file}
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "Synthesis failed: [get_property STATUS [get_runs synth_1]]"
}
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "Implementation failed: [get_property STATUS [get_runs impl_1]]"
}
open_run impl_1
report_utilization -file [file join $reports_dir utilization.rpt]
report_drc -file [file join $reports_dir drc.rpt]
report_cdc -file [file join $reports_dir cdc.rpt]
report_clock_interaction -file [file join $reports_dir clocks.rpt]
set timing_text [report_timing_summary -delay_type min_max -report_unconstrained -return_string]
set report [open [file join $reports_dir timing.rpt] w]
puts $report $timing_text
close $report
if {![string match {*All user specified timing constraints are met.*} $timing_text]} {
    error "Timing failed; review reports/timing.rpt before programming."
}
foreach kind {max min} {
    set worst [get_timing_paths -delay_type $kind -max_paths 1 -nworst 1]
    if {![llength $worst] || [get_property SLACK $worst] < 0} {
        error "$kind timing failed or no paths found."
    }
}
set bitstream [file normalize [file join $project_dir camera_test_basys3.runs impl_1 basys3_camera_test_top.bit]]
if {![file isfile $bitstream]} {error "Bitstream was not generated."}
set validation [open $validated_file w]
puts $validation [list $bitstream [file size $bitstream] [file mtime $bitstream]]
close $validation
puts "CAMERA_TEST_BUILD_OK"
close_project
