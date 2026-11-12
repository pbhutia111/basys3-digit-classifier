# Volatile SRAM programming only; normal camera bitstream is retained separately.
set workspace [file dirname [file dirname [file normalize [info script]]]]
set bitstream [file join $workspace build camera_wiring_test basys3_camera_wiring_test_top.bit]
set validated_file [file join $workspace reports camera_wiring_test validated_bitstream.txt]
if {![file isfile $bitstream] || ![file isfile $validated_file]} {
    error "Build and validate the camera wiring test first."
}
set f [open $validated_file r]
set expected [string trim [read $f]]
close $f
if {$expected ne [list [file normalize $bitstream] [file size $bitstream] [file mtime $bitstream]]} {
    error "Wiring-test bitstream changed after validation."
}
open_hw_manager
connect_hw_server
set targets [get_hw_targets]
if {[llength $targets] != 1} {error "Expected exactly one connected Basys 3 target."}
open_hw_target [lindex $targets 0]
set candidates {}
foreach d [get_hw_devices] {
    if {[get_property PART $d] eq "xc7a35t"} {lappend candidates $d}
}
if {[llength $candidates] != 1} {error "Expected exactly one XC7A35T device."}
set device [lindex $candidates 0]
current_hw_device $device
refresh_hw_device $device
set_property PROGRAM.FILE $bitstream $device
program_hw_devices $device
refresh_hw_device $device
puts "CAMERA_WIRING_TEST_PROGRAMMED=$bitstream"
close_hw_target
disconnect_hw_server
close_hw_manager
