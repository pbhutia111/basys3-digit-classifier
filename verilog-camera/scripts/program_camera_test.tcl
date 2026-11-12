# Volatile SRAM programming only. No flash writes.
set workspace [file dirname [file dirname [file normalize [info script]]]]
set bitstream [file join $workspace build camera_test_basys3 camera_test_basys3.runs impl_1 basys3_camera_test_top.bit]
set validated_file [file join $workspace reports camera_test validated_bitstream.txt]
if {![file isfile $bitstream] || ![file isfile $validated_file]} {
    error "Run Build-Camera-Test.cmd and pass timing first."
}
set f [open $validated_file r]
set expected [string trim [read $f]]
close $f
if {$expected ne [list [file normalize $bitstream] [file size $bitstream] [file mtime $bitstream]]} {
    error "Bitstream changed after validation; rebuild before programming."
}
open_hw_manager
connect_hw_server
set targets [get_hw_targets]
if {[llength $targets] != 1} {error "Connect exactly one powered Basys 3 programming target."}
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
puts "CAMERA_PROGRAMMED=$bitstream"
close_hw_target
disconnect_hw_server
close_hw_manager
