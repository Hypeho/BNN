create_clock -name cpu_clk -period 28.572 [get_ports cpu_clk]
create_clock -name bram_clk -period 9.524 [get_ports bram_clk]

# CPU/BDOT logic is entirely in cpu_clk. BRAM read ports use the synchronous
# 1:3 phase-aligned overclock from the same Clock Wizard. Both OOC periods use
# integer-picosecond values with an exact 1:3 ratio, avoiding a false 0.001 ns
# inter-clock requirement from decimal rounding. No request/result CDC exceptions
# exist.

set_false_path -from [get_ports async_reset]
