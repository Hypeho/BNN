# CPU and BDOT control/datapath share the 35 MHz CPU clock. The Clock Wizard's
# related 105 MHz output drives IMEM/DMEM CPU ports and all wide BRAM ports.
# These paths remain normally timed; the former request/result CDC exceptions
# are intentionally removed.

# reset_sync uses asynchronous assertion and two-stage synchronous release.
set_false_path -to [get_pins -quiet -hier -filter {
    NAME =~ *reset_sync*/sync_ff_reg*/PRE
}]
