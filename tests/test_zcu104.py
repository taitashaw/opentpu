"""The ZCU104 port (targets/zcu104.toml, rtl/boards/zcu104, boards/zcu104): the target is the
card's accelerator, and the board model runs programs through the ZCU104's memory path
(otpu_mem_ch per channel, otpu_mig_mux, a model of the SODIMM's DDR4 controller)."""
import re
from pathlib import Path

import pytest

from opentpu.host.board import Board, SimTransport
from opentpu.host.checks import masked_program, run_demo
from opentpu.target import arch_hash, build_config, load, rtl_params, sources
from conftest import sim_board_config

ROOT = Path(__file__).resolve().parent.parent
CFG = sim_board_config(DRAM_BYTES=1 << 22)


def test_same_accelerator_as_the_card():
    """The same [arch] as the YPCB-00338's m4 variant: the same arch_hash (CFG_HASH), so the
    compiler's programs for the card run on the ZCU104 as they are."""
    z, c = load("zcu104"), load("ypcb-00338:m4")
    assert z.arch == c.arch
    assert arch_hash(build_config(z)) == arch_hash(build_config(c))
    assert z.platform_id != c.platform_id


def test_sources_exist_and_end_with_the_top():
    files = sources(load("zcu104"))
    for f in files:
        assert (ROOT / "rtl" / f).is_file(), f
    assert files[-1] == "boards/zcu104/otpu_fpga_top_zcu104.sv"
    assert "boards/ypcb-00338/otpu_native_sys.sv" in files       # the card's system as it is
    assert "tech/xilinxus/otpu_tech_dsp.sv" in files              # UltraScale+ DSP48E2


# the block design's cell tpu: the card's system with the target's parameters
TPU = ROOT / "rtl/boards/zcu104/otpu_zbd_tpu.v"
_PARAM = r"parameter\s+(?:integer|\[[^\]]*\])\s+(\w+)"


def test_block_design_references_the_targets_modules():
    """bd_zcu104.tcl's module references (tpu, merge, ddr4) name modules the target's files
    define, and the top instantiates the block design's wrapper only."""
    tcl = (ROOT / "boards/zcu104/vivado/bd_zcu104.tcl").read_text()
    refs = re.findall(r"create_bd_cell -type module -reference (\w+) (\w+)", tcl)
    assert {c for _, c in refs} == {"tpu", "merge", "ddr4"}, refs
    text = "\n".join((ROOT / "rtl" / f).read_text() for f in sources(load("zcu104")))
    for m, _ in refs:
        assert re.search(r"^module %s\b" % m, text, re.M), m
    top = (ROOT / "rtl/boards/zcu104/otpu_fpga_top_zcu104.sv").read_text()
    assert re.findall(r"^\s*(\w+)(?:\s+#\(.*?\))?\s+u_\w+\s*\(", top, re.M | re.S) == ["otpu_zbd_wrapper"]


def test_cells_controller_ports_line_up():
    """otpu_zbd_tpu and otpu_zbd_mux flatten otpu_native_sys's / otpu_mig_mux's [channel][port]
    arrays the same way: the block design connects their c_* pins by name, width for width."""
    def widths(path):
        return {n: int(w) for w, n in re.findall(r"(?:input|output)\s+wire\s+\[(\d+):0\]\s+(c_\w+)",
                                                  path.read_text())}
    t, m = widths(TPU), widths(ROOT / "rtl/boards/zcu104/otpu_zbd_mux.v")
    assert len(t) == 10 and t == m, (t, m)
    assert t["c_cmd_addr"] + 1 == 4 * 25 and t["c_wdata_data"] + 1 == 4 * 512


def test_create_project_passes_only_the_cells_parameters():
    """create_project.tcl's parameter lists name parameters the cell tpu (otpu_zbd_tpu) has
    (bd_zcu104.tcl reads each value back from the cell, and stops on one it did not take)."""
    params = set(re.findall(_PARAM, TPU.read_text()))
    tcl = (ROOT / "boards/zcu104/vivado/create_project.tcl").read_text()
    named = set()
    for lst in ("bits", "ints"):
        m = re.search(r"set %s \{([^}]*)\}" % lst, tcl)
        assert m, lst
        named |= set(m.group(1).split())
    named |= {"CORE_KHZ", "BUILD_ID", "ARCH_HASH", "COLL_GATHER"}
    assert named <= params, named - params


@pytest.mark.parametrize("stall,seed", [(30, 3), (0, 5), (70, 7)])
def test_program_on_mig_board_model(have_verilator, stall, seed):
    """The card's demo programs on the ZCU104's memory (tb_board MEM_NATIVE=3: per channel
    otpu_mem_ch, then the two channels' four controller ports merged by otpu_mig_mux onto a model
    of the SODIMM's DDR4 controller, the MIG's native interface in its own clock, app_rdy and
    app_wdf_rdy withheld at random): the results equal the ISA simulator's, and every write's
    data reaches the controller with or before its command (otpu_mig_model's checks)."""
    b = Board(SimTransport(ch_bytes=CFG.DRAM_BYTES // 2, stall=stall, seed=seed, native="mig"))
    ok, msg, st = run_demo(b, CFG)
    assert ok, msg
    assert st["b_reads"] > 0 and st["a_writes"] > 0 and st["cycles"] > 0
    assert re.search(r"MIG s0 rd=\d+ wr=\d+ ", b.t.out), b.t.out[-2000:]   # the MIG path ran
    ok, msg, st = run_demo(b, CFG, masked_program())
    assert ok, msg
    assert st["a_writes"] > 500 and st["b_writes"] > 20


def _core_files(target: str) -> list[str]:
    """opentpu.core's RTL for one of its targets, in file-set order (rtl/ stripped)."""
    yaml = pytest.importorskip("yaml")
    core = yaml.safe_load((ROOT / "opentpu.core").read_text().split("\n", 1)[1])
    out = []
    for fs in core["targets"][target]["filesets"]:
        for f in core["filesets"][fs]["files"]:
            f = next(iter(f)) if isinstance(f, dict) else f
            if f.startswith("rtl/"):
                out.append(f[4:])
    return out


@pytest.mark.parametrize("target,family", [("default", "generic"), ("zcu104", None)])
def test_fusesoc_core_lists_the_targets_sources(target, family):
    """opentpu.core's targets compile the files opentpu/target.py names, in its order (the
    default target: the vendor-neutral system, without a board top)."""
    want = sources(load("zcu104"), family)
    if target == "default":
        want = [f for f in want if not f.startswith("boards/zcu104/")]
    assert _core_files(target) == want
    for f in _core_files(target):
        assert (ROOT / "rtl" / f).is_file(), f


def _sv_value(s: str) -> int:
    s = s.strip()
    m = re.fullmatch(r"(\d+)?'([bhd])([0-9a-fA-F_]+)", s)
    if m:
        return int(m.group(3).replace("_", ""), {"b": 2, "h": 16, "d": 10}[m.group(2)])
    m = re.fullmatch(r"1\s*<<\s*(\d+)", s)
    return 1 << int(m.group(1)) if m else int(s)


def test_cell_defaults_are_the_targets():
    """otpu_zbd_tpu's parameter defaults are targets/zcu104.toml's values, its arch_hash
    included: the FuseSoC build, which sets no cell parameter, builds the bitstream
    create_project.tcl builds (BUILD_ID aside)."""
    head = TPU.read_text().split(") (", 1)[0]
    d = dict(re.findall(_PARAM + r"\s*=\s*([^,\n)]+)", head))
    t = rtl_params(load("zcu104"))
    shared = set(d) & set(t)
    assert len(shared) >= 19 and "ARCH_HASH" in shared, shared
    assert {k: d[k] for k in shared if _sv_value(d[k]) != int(t[k])} == {}
    assert _sv_value(d["CORE_KHZ"]) == 133333
