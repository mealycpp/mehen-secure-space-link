############################################################
## This file is generated automatically by Vitis HLS.
## Please DO NOT edit it.
## Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
############################################################
open_project trng_core
set_top trng_core
add_files trng_core/rtl/trng_core.hpp
add_files trng_core/rtl/trng_core.cpp
add_files -tb trng_core/tb/tb_trng_core.cpp -cflags "-Wno-unknown-pragmas" -csimflags "-Wno-unknown-pragmas"
open_solution "solution1" -flow_target vivado
set_part {xczu3eg-sfvc784-2-e}
create_clock -period 3 -name default
#source "./trng_core/solution1/directives.tcl"
csim_design
csynth_design
cosim_design
export_design -rtl verilog -format ip_catalog
