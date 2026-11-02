# The ZCU104's memory placement: read before synthesis (create_project.tcl, synthesis only;
# fit_check.tcl). The XCZU7EV has 312 RAMB36 and 96 URAM288 (the card's XC7K480T has 955 RAMB36
# and no URAM). At the card's parameters the block RAM runs short and Vivado builds the
# activation RAM out of LUTs (16 pieces of 512 x 256 bits, 68K LUTs). These overrides move it,
# and the trace buffer, into UltraRAM. RAM_STYLE changes where a memory lives, not what it does:
# the RTL (a registered read, byte-enable writes) is unchanged, so the numerics are the card's
# bit for bit. An XDC property overrides the RTL's ram_style attribute (the trace's "block").
#   activation RAM: otpu_actram g_row[r].g_pc[p].u_act, 512 x 256 bits each, 4 URAM a piece = 64
#   trace buffer:   otpu_trace mem, TRACE_DEPTH 16384 x 64 bits = 4 URAM (frees 28 RAMB36)
# Plain XDC (no Tcl control flow: Vivado's XDC parser drops "if"); build.tcl checks the URAM count
# after synthesis, so a pattern that stops matching fails the build instead of passing quietly.

set_property RAM_STYLE ULTRA [get_cells -hierarchical -filter {NAME =~ *u_act/g_row*u_act/*mem_reg*}]
set_property RAM_STYLE ULTRA [get_cells -hierarchical -filter {NAME =~ *g_trace.u_trace/mem_reg*}]
