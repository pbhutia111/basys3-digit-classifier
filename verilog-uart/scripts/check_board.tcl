# Read-only USB/JTAG discovery; does not program or modify the board.
open_hw_manager
connect_hw_server
set targets [get_hw_targets -quiet]
puts "BASYS3_TARGET_COUNT=[llength $targets]"
foreach target $targets {
    puts "PROGRAMMING_TARGET=$target"
    open_hw_target $target
    foreach device [get_hw_devices -quiet] {
        puts "DETECTED_DEVICE=$device PART=[get_property PART $device]"
    }
    close_hw_target
}
disconnect_hw_server
close_hw_manager
