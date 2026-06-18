"""
memcached utdelay pause_per_round sweep — cross-architecture experiment profile

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
# Architecture → hardware type mapping
# Wisconsin (CloudLab) node types. Update if using a different cluster.
# ---------------------------------------------------------------------------
arch_options = [
    ("skylake",        "Skylake       (c220g5 / Xeon Silver 4114)"),
    ("broadwell",      "Broadwell     (c220g4 / Xeon E5-2630 v4)"),
    ("ivybridge",      "Ivy Bridge    (c220g2 / Xeon E5-2660 v2)"),
    ("icelake",        "Ice Lake      (c6420  / Xeon Gold 6338)"),
    ("emeraldrapids",  "Emerald Rapids(c6620  / Xeon Gold 6554S)"),
]

# Hardware type strings for each arch (Wisconsin cluster defaults)
# Edit here if instantiating on a different cluster
HW_MAP = {
    "skylake":        "c220g5",
    "broadwell":      "c220g4",
    "ivybridge":      "c220g2",
    "icelake":        "c6420",
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

# Ubuntu 22.04: known to work with our build (apt packages verified)
node.disk_image = "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD"

if hw_type:
    node.hardware_type = hw_type

# ---------------------------------------------------------------------------
# Startup: auto-run setup_cloudlab.sh
# Runs as the experiment user (not root); sudo is available inside the script.
# Log: ~/setup_memcached.log
# ---------------------------------------------------------------------------
SETUP_URL = (
    "https://raw.githubusercontent.com/hikaru2003/memcached"
    "/experiment/mysql-like-utdelay/experiment/setup_cloudlab.sh"
)

node.addService(pg.Execute(
    shell="bash",
    command=(
        f"curl -fsSL '{SETUP_URL}' | bash > $HOME/setup_memcached.log 2>&1"
    )
))

# Print the RSpec
pc.printRequestRSpec(request)
