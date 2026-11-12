# Program the Basys 3's volatile FPGA SRAM. This does not write onboard flash.
set workspace [file dirname [file dirname [file normalize [info script]]]]
set bitstream [file join $workspace build mnist_basys3 mnist_basys3.runs impl_1 basys3_mnist_top.bit]
if {![file isfile $bitstream]} {error "Build the bitstream first: $bitstream"}
set validated_file [file join $workspace reports validated_bitstream.txt]
if {![file isfile $validated_file]} {error "Run scripts/build.tcl and pass timing before programming."}
set validation [open $validated_file r]
set expected [string trim [read $validation]]
close $validation
set actual [list [file normalize $bitstream] [file size $bitstream] [file mtime $bitstream]]
if {$expected ne $actual} {error "The bitstream changed after timing validation; rebuild before programming."}
open_hw_manager
connect_hw_server
set targets [get_hw_targets]
if {[llength $targets] != 1} {error "Expected exactly one connected programming target, found [llength $targets]. Connect the powered Basys 3."}
open_hw_target [lindex $targets 0]
set candidates {}
foreach device [get_hw_devices] {
    if {[get_property PART $device] eq "xc7a35t"} {lappend candidates $device}
}
if {[llength $candidates] != 1} {error "Expected one Basys 3 XC7A35T device, found [llength $candidates]."}
set device [lindex $candidates 0]
current_hw_device $device
refresh_hw_device $device
set_property PROGRAM.FILE $bitstream $device
program_hw_devices $device
refresh_hw_device $device
puts "BASYS3_PROGRAMMED=$bitstream"
close_hw_target
disconnect_hw_server
close_hw_manager
