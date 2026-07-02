"""
memcached utdelay pause_per_round sweep - cross-architecture experiment profile

Single bare-metal node for measuring PAUSE latency characteristics per CPU
microarchitecture (Ivy Bridge, Broadwell, Skylake, Ice Lake, Emerald Rapids).

setup_cloudlab.sh runs automatically at node startup:
  - Installs build dependencies (apt)
  - Clones hikaru2003/memcached @ experiment/mysql-like-utdelay and builds
  - Clones leverich/mutilate, patches SConstruct for Python3, builds
  - Detects arch and generates ~/run_utdelay_experiment.sh

After node is ready:
  ssh -A <node>
  tail -f ~/setup_memcached.log          # setup progress
  bash ~/run_utdelay_experiment.sh        # run experiment
  cd ~/Application/memcached && bash experiment/push_results.sh  # push results
"""

import geni.portal as portal
import geni.rspec.pg as pg
import geni.rspec.emulab as emulab

pc = portal.Context()
request = pc.makeRequestRSpec()

# ---------------------------------------------------------------------------
# Architecture -> hardware type mapping
# Verified from simple_mysql experiment results on CloudLab.
# PAUSE cycles/instr measured values (from result/2026_6_3/README.md):
#   ivy_c8220:     14.56 cyc   broadwell_xl170: 12.34 cyc
#   skylake_c220g5: 141.97 cyc  icelake_sm110:  38.86 cyc
#   emerald_c6620:  37.15 cyc
# ---------------------------------------------------------------------------
arch_options = [
    ("skylake",        "Skylake       (c220g5 / Xeon Silver 4114,  PAUSE~142cyc)"),
    ("broadwell",      "Broadwell     (xl170  / Xeon E5-2640 v4,   PAUSE~12cyc)"),
    ("ivybridge",      "Ivy Bridge    (c8220  / Xeon E5-2650 v2,   PAUSE~15cyc)"),
    ("icelake",        "Ice Lake      (sm110  / Xeon Gold 6338,    PAUSE~39cyc)"),
    ("emeraldrapids",  "Emerald Rapids(c6620  / Xeon Gold 6554S,   PAUSE~37cyc)"),
]

# Hardware type strings - verified against simple_mysql result directory names
HW_MAP = {
    "skylake":        "c220g5",
    "broadwell":      "xl170",
    "ivybridge":      "c8220",
    "icelake":        "sm110",
    "emeraldrapids":  "c6620",
}

pc.defineParameter(
    "arch", "Target Architecture",
    portal.ParameterType.STRING,
    arch_options[0][0], arch_options,
    longDescription="CPU microarchitecture to test. Each maps to a specific "
                    "hardware type on the Wisconsin cluster.")

pc.defineParameter(
    "phystype_override", "Hardware type override",
    portal.ParameterType.NODETYPE, "",
    longDescription="Leave empty to use the arch default from HW_MAP. "
                    "Set explicitly if on a different cluster "
                    "(e.g., 'm400' for ARM, 'r7525' for AMD EPYC).")

params = pc.bindParameters()
pc.verifyParameters()

arch     = params.arch
hw_type  = params.phystype_override if params.phystype_override else HW_MAP.get(arch, "")

# ---------------------------------------------------------------------------
# Node definition
# ---------------------------------------------------------------------------
node = request.RawPC("node0")

# Ubuntu 24.04: matches simple_mysql profile default (verified on all 5 arch nodes)
node.disk_image = "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU24-64-STD"

if hw_type:
    node.hardware_type = hw_type

# ---------------------------------------------------------------------------
# Startup: auto-run setup_cloudlab.sh
# pg.Execute runs as root on CloudLab; log to /tmp/ (world-readable).
# setup_cloudlab.sh detects the non-root experiment user automatically.
# Log: /tmp/setup_memcached.log
# ---------------------------------------------------------------------------
SETUP_URL = (
    "https://raw.githubusercontent.com/hikaru2003/memcached"
    "/results/experiment/setup_cloudlab.sh"
)

node.addService(pg.Execute(
    shell="bash",
    command="wget -q -O /local/setup_memcached.sh '{}'".format(SETUP_URL)
))
node.addService(pg.Execute(
    shell="bash",
    command="sudo bash /local/setup_memcached.sh > /tmp/setup_memcached.log 2>&1"
))

# Print the RSpec
pc.printRequestRSpec(request)
