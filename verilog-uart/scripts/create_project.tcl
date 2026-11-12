# Reproducible Basys 3 project. The upstream MIT core remains unchanged.
set script_dir [file dirname [file normalize [info script]]]
set workspace [file dirname $script_dir]
set upstream [file normalize [file join $workspace .. repos neural-net-on-fpga]]
set project_dir [file join $workspace build mnist_basys3]
set project_file [file join $project_dir mnist_basys3.xpr]
set reports_dir [file join $workspace reports]
file mkdir $reports_dir

if {[current_project -quiet] ne ""} {
    if {[file normalize [get_property DIRECTORY [current_project]]] ne [file normalize $project_dir]} {
        error "Save and close the other project before opening this project."
    }
} elseif {[file exists $project_file]} {
    open_project $project_file
} else {
    set rtl [concat [glob [file join $workspace rtl *.v]] [list \
        [file join $upstream hdl src inference_engine.v] \
        [file join $upstream hdl src weight_rom.v]]]
    set weights [glob [file join $upstream hdl weights *.mem]]
    foreach f [concat $rtl $weights [list [file join $workspace constraints basys3_uart.xdc]]] {
        if {![file isfile $f]} {error "Missing source: $f"}
    }
    create_project mnist_basys3 $project_dir -part xc7a35tcpg236-1
    set_property target_language Verilog [current_project]
    set_property simulator_language Mixed [current_project]
    add_files -norecurse $rtl
    add_files -norecurse $weights
    set_property top basys3_mnist_top [get_filesets sources_1]
    add_files -fileset constrs_1 [file join $workspace constraints basys3_uart.xdc]
    set benches [glob -nocomplain [file join $workspace tb *.v]]
    if {[llength $benches]} {add_files -fileset sim_1 -norecurse $benches}
    set fixtures [glob -nocomplain [file join $workspace verification *.mem]]
    if {[llength $fixtures]} {add_files -fileset sim_1 -norecurse $fixtures}
    set_property top tb_basys3_mnist [get_filesets sim_1]
    set_property xsim.simulate.runtime all [get_filesets sim_1]
    set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY rebuilt [get_runs synth_1]
    update_compile_order -fileset sources_1
    update_compile_order -fileset sim_1
}
# Discover newly added RTL when reopening an existing project as well.
foreach f [glob [file join $workspace rtl *.v]] {
    if {![llength [get_files -quiet $f]]} {add_files -norecurse $f}
}
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts "BASYS3_PROJECT=$project_file"
