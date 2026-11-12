# Prepare InduwaraGunasena/SNN-FPGA for the Basys 3 without modifying its checkout.
# Run in Vivado: source {C:/path/to/basys3-digit-classifier/scripts/create_snn_project.tcl}
# Or: vivado -mode gui -source scripts/create_snn_project.tcl
# This script creates/opens a project only; it does not synthesize or program a board.

set script_dir [file dirname [file normalize [info script]]]
set workspace_dir [file dirname $script_dir]
set checkout_dir [file join $workspace_dir repos SNN-FPGA]
set source_root [file join $checkout_dir snn-fpga snn-fpga.srcs]
set design_root [file join $source_root sources_1 new]
set simulation_root [file join $source_root sim_1 new]
set project_name snn_basys3
set project_dir [file join $workspace_dir build $project_name]
set project_file [file join $project_dir ${project_name}.xpr]
set target_part xc7a35tcpg236-1

if {[llength [info commands create_project]] == 0} {
    error "Run this script inside AMD Vivado, for example: vivado -mode gui -source \"[info script]\""
}

# Do not close another project or overwrite an existing project's settings.
set active_project [current_project -quiet]
if {$active_project ne ""} {
    set active_dir [file normalize [get_property DIRECTORY $active_project]]
    if {$active_project eq $project_name && $active_dir eq [file normalize $project_dir]} {
        puts "The SNN project is already open: $project_file"
        return
    }
    error "Another Vivado project is open ($active_project). Save and close it, then source this script again."
}

if {[file isfile $project_file]} {
    open_project $project_file
    puts "Opened existing project without recreating it: $project_file"
    return
}

if {![file isdirectory $checkout_dir]} {
    error "SNN-FPGA checkout is missing: $checkout_dir. Restore or clone https://github.com/InduwaraGunasena/SNN-FPGA into that directory, then rerun this script."
}

# Packages precede their users; leaf modules precede their parent entities.
# Use the weights from the HDL sources, not the reference copy in Python scripts/.
set design_files [list \
    [file join $design_root packages types_pkg.vhd] \
    [file join $design_root packages weights_pkg.vhd] \
    [file join $design_root layers fc_layer_seq.vhd] \
    [file join $design_root layers lif_array_seq.vhd] \
    [file join $design_root uart uart_rx.vhd] \
    [file join $design_root uart uart_tx.vhd] \
    [file join $design_root uart uart_frame_receiver256.vhd] \
    [file join $design_root top seven_seg.vhd] \
    [file join $design_root top snn_core.vhd] \
    [file join $design_root top top_fpga.vhd] \
]
set simulation_files [list \
    [file join $simulation_root tb_fc_layer_seq.vhd] \
    [file join $simulation_root tb_snn_core.vhd] \
]
set constraint_file [file join $source_root constrs_1 imports Downloads Basys3Labs.xdc]

# Complete preflight before creating project files.
foreach source_file [concat $design_files $simulation_files [list $constraint_file]] {
    if {![file isfile $source_file]} {
        error "Required upstream file is missing: $source_file. Restore a complete SNN-FPGA checkout and rerun this script."
    }
}
if {[llength [get_parts -quiet $target_part]] == 0} {
    error "Vivado cannot find $target_part. Add Artix-7 device support to the Vivado installation, then rerun this script."
}
if {[file exists $project_dir]} {
    set existing_entries [concat \
        [glob -nocomplain -directory $project_dir *] \
        [glob -nocomplain -directory $project_dir .*]]
    foreach entry $existing_entries {
        if {[file tail $entry] ni [list . ..]} {
            error "Project directory contains files but no $project_name.xpr: $project_dir. Preserve or move that directory before retrying; nothing has been overwritten."
        }
    }
}

create_project $project_name $project_dir -part $target_part
set_property target_language VHDL [current_project]
set_property simulator_language Mixed [current_project]
set_property default_lib xil_defaultlib [current_project]

add_files -norecurse -fileset sources_1 $design_files
set_property file_type {VHDL 2008} [get_files -of_objects [get_filesets sources_1]]
set_property library xil_defaultlib [get_files -of_objects [get_filesets sources_1]]
set_property top top_fpga [get_filesets sources_1]

add_files -norecurse -fileset constrs_1 [list $constraint_file]

add_files -norecurse -fileset sim_1 $simulation_files
set_property file_type {VHDL 2008} [get_files -of_objects [get_filesets sim_1]]
set_property library xil_defaultlib [get_files -of_objects [get_filesets sim_1]]
set_property top tb_snn_core [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "Created SNN project: $project_file"
puts "Design top: top_fpga. Simulation top: tb_snn_core. No synthesis or hardware programming has run."
puts "The upstream simulation benches provide stimulus and reports; they do not establish classification accuracy."
puts "Clock review required before timing signoff: top_fpga derives 25 MHz from clk_div(1), while the upstream XDC constrains only the 100 MHz input. Inspect the synthesized clock tree, report_clocks and check_timing; validate generated-clock constraints and clock routing before relying on timing results."
