# Pre-synthesis hook of the block design's tpu cell when it synthesizes out of context
# (build.tcl, OTPU_BD_OOC=1): the same memory placement synth_1 reads (act_uram.xdc's
# hierarchical patterns match below the cell too). build.tcl's URAM count checks it took.
read_xdc [file join [file dirname [file normalize [info script]]] act_uram.xdc]
