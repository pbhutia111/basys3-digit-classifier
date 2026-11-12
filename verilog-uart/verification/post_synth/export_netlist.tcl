set work_dir [file dirname [file normalize [info script]]]
set dcp [file normalize [file join $work_dir ../../build/mnist_basys3/mnist_basys3.runs/synth_1/basys3_mnist_top.dcp]]
open_checkpoint $dcp
write_verilog -force -mode funcsim [file join $work_dir basys3_mnist_funcsim.v]
report_utilization -file [file join $work_dir utilization.rpt]
close_design
exit
