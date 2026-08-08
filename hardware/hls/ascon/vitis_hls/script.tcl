############################################################
## This file is generated automatically by Vitis HLS.
## Please DO NOT edit it.
## Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
############################################################
open_project ascon
set_top ascon_core
add_files ascon/rtl_hls/ascon_perm.hpp
add_files ascon/rtl_hls/ascon_perm.cpp
add_files ascon/rtl_hls/ascon_core.hpp
add_files ascon/rtl_hls/ascon_core.cpp
add_files ascon/rtl_hls/ascon_aead.hpp
add_files ascon/rtl_hls/ascon_aead.cpp
add_files -tb ascon/tb/tb_ascon_core.cpp -cflags "-Wno-unknown-pragmas" -csimflags "-Wno-unknown-pragmas"
open_solution "solution1" -flow_target vivado
set_part {xczu3eg-sfvc784-2-e}
create_clock -period 3 -name default
config_export -flow syn -format ip_catalog -rtl verilog -vivado_clock 3
source "./ascon/solution1/directives.tcl"
csim_design
csynth_design
cosim_design
export_design -flow syn -rtl verilog -format ip_catalog
