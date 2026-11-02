"""Export a target's accelerator system as a tool-neutral netlist: otpu_native_sys (the slice,
its DRAM adapter, the control block and trace, one otpu_mem_ch per channel, the host DMA's split)
at the target's parameters, built from the generic cells (rtl/tech/generic: behavioural RAMs and
multipliers, no vendor primitive), elaborated by yosys with the slang SystemVerilog front end.

    python3 tools/neutral/export.py [TARGET]     (default zcu104)

Writes build/neutral/<target>/:
  otpu_native_sys.v     one Verilog-2005 file, parameters resolved, hierarchy kept: any FPGA
                        or ASIC tool reads it and maps the memories and multipliers itself
  otpu_native_sys.json  the same netlist in yosys's JSON (yosys, nextpnr flows)
  otpu_native_sys.il    the same in RTLIL (yosys)
  MANIFEST.txt          the target, its parameters, the sources and their SHA-256, the tools
  stat.txt              yosys's cell counts
The board around it (clocks, the memory controller, the host link) is each board's own: the
ports are otpu_native_sys's (rtl/boards/ypcb-00338/otpu_native_sys.sv).

Yosys: YOSYS, else the oss-cad-suite's under ~/.apio, else yosys on PATH, with the slang plugin
(as tools/asic/flow.py). TMPDIR is kept short and COLUMNS wide (yosys-abc's pipe hangs otherwise).
"""
from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from opentpu.target import arch_hash, build_config, load, rtl_params, sources  # noqa: E402

TOP = "otpu_native_sys"
SYS = ROOT / "rtl/boards/ypcb-00338/otpu_native_sys.sv"


def yosys() -> str:
    if os.environ.get("YOSYS"):
        return os.environ["YOSYS"]
    apio = Path.home() / ".apio/packages/oss-cad-suite/bin/yosys"
    if apio.exists():
        return str(apio)
    if shutil.which("yosys"):
        return "yosys"
    raise RuntimeError("no yosys with the slang plugin: set YOSYS")


def sys_params() -> set[str]:
    head = SYS.read_text().split(");", 1)[0]
    return set(re.findall(r"parameter\s+(?:int|bit|string|logic\s*\[[^\]]*\])\s+(\w+)", head))


def params(t) -> dict:
    """otpu_native_sys's parameters for target t: the target's rtl_params that the module has,
    plus the board knobs it takes from the platform (the core clock as its MMCM makes it, whether
    the host calibrates the controllers; register slices at the host split, latency only)."""
    have = sys_params()
    p = {k: v for k, v in rtl_params(t).items() if k in have}
    mhz = t.platform["core_mhz"]
    p["CORE_KHZ"] = 133333 if abs(mhz - 133.33) < 0.01 else round(mhz * 1000)
    p["HOSTCAL"] = int(bool(t.platform.get("hostcal", False)))
    p["XREG"] = 1
    p.setdefault("COLL_GATHER", 0)
    p.setdefault("TMEM_SBP", 3)
    p["ARCH_HASH"] = arch_hash(build_config(t))
    p = {k: int(v) for k, v in p.items()}
    missing = set(p) - have
    if missing:
        raise RuntimeError(f"not parameters of {TOP}: {sorted(missing)}")
    return p


def main(argv: list[str]) -> int:
    name = argv[0] if argv else "zcu104"
    t = load(name)
    files = [ROOT / "rtl" / f for f in sources(t, "generic") if not f.startswith("boards/")]
    files.append(SYS)
    p = params(t)
    out = ROOT / "build" / "neutral" / name.replace(":", "_")
    out.mkdir(parents=True, exist_ok=True)
    g = " ".join(f"-G {k}={v}" for k, v in sorted(p.items()))
    f = " ".join(str(x) for x in files)
    script = (f"read_slang -D SYNTHESIS --keep-hierarchy --ignore-assertions "
              f"--allow-use-before-declare {f} --top {TOP} {g}; "
              f"hierarchy -check -top {TOP}; proc; opt_clean; memory_collect; "
              # a word write's enable is one bit repeated: as one bit, write_verilog writes the
              # port as one word write (64 one-bit writes otherwise, which Vivado cannot infer as
              # a RAM: Synth 8-4556 on the trace buffer)
              f"opt_reduce -full; opt_clean; "
              # yosys cells with no Verilog form (write_verilog would leave them as instances)
              f"bwmuxmap; bmuxmap; demuxmap; opt_clean; "
              f"check -assert; tee -q -o {out}/stat.txt stat; "
              f"write_verilog -noattr {out}/{TOP}.v; write_json {out}/{TOP}.json; "
              f"write_rtlil {out}/{TOP}.il")
    tmp = Path("/tmp/st/t")
    tmp.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, TMPDIR=str(tmp), COLUMNS="65536")
    ys = yosys()
    r = subprocess.run([ys, "-m", "slang", "-q", "-l", str(out / "yosys.log"), "-p", script],
                       env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-3000:], r.stderr[-3000:], file=sys.stderr)
        return 1
    ver = subprocess.run([ys, "-V"], capture_output=True, text=True).stdout.strip()
    git = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True,
                         text=True).stdout.strip()
    lines = [f"target {name} (arch_hash {p['ARCH_HASH']:08x}, platform {t.platform_id})",
             f"top {TOP}", f"repository {git}", f"tool {ver} with slang",
             "parameters " + " ".join(f"{k}={v}" for k, v in sorted(p.items())), "sources"]
    for x in files:
        lines.append(f"  {hashlib.sha256(x.read_bytes()).hexdigest()}  {x.relative_to(ROOT)}")
    lines.append("outputs")
    for o in (f"{TOP}.v", f"{TOP}.json", f"{TOP}.il"):
        b = (out / o).read_bytes()
        lines.append(f"  {hashlib.sha256(b).hexdigest()}  {o}  {len(b)} bytes")
    left = sorted(set(re.findall(r"^\s+\\?(\$[a-z_0-9]+) ", (out / f"{TOP}.v").read_text(), re.M)))
    if left:
        print(f"yosys-internal cells left in {TOP}.v: {left}", file=sys.stderr)
        return 1
    (out / "MANIFEST.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
