"""
memcached PAUSE sweep - cross-architecture experiment profile

Single bare-metal node for measuring PAUSE latency characteristics per CPU
microarchitecture. Any hardware type available on the cluster can be selected.

setup_cloudlab.sh (fetched from results branch) runs automatically at node startup:
  - Installs build dependencies (apt: build-essential, libevent, scons, numpy, ...)
  - Builds memcached        @ experiment/mysql-like-utdelay  -> memcached
  - Builds memcached_master @ master                         -> memcached_master
  - Builds memcached_wait_debug @ debug/wait-time            -> memcached_wait_debug
  - Builds mutilate_p999 (ConnectionStats.h patched for p50+p999)
  - Detects arch from /proc/cpuinfo, generates ~/run_utdelay_experiment.sh
  - Sets up myfork remote = git@github.com:hikaru2003/memcached.git

After node is ready:
  ssh -A <node>                                              # -A required for git push
  tail -f /tmp/setup_memcached.log                           # setup progress (~10-15 min)
  sudo bash experiment/setup_perf_env.sh                     # SMT off, turbo off, perf gov
  cd ~/Application/memcached
  bash experiment/run_trial.sh                               # short verification (both experiments)
  bash ~/run_utdelay_experiment.sh                           # full utdelay sweep (~12.6h)
  bash experiment/run_wait_distribution.sh                   # full wait distribution (~5.3h)
  bash experiment/push_results.sh                            # push utdelay results
  EXPERIMENT_TYPE=wait bash experiment/push_results.sh       # push wait results

Known hardware types (Wisconsin cluster):
  c220g5  Skylake       Xeon Silver 4114   PAUSE~124cyc
  xl170   Broadwell     Xeon E5-2640 v4    PAUSE~10cyc
  c8220   Ivy Bridge    Xeon E5-2650 v2    PAUSE~15cyc
  sm110   Ice Lake      Xeon Gold 6338     PAUSE~39cyc
  c6620   Emerald Rapids Xeon Gold 6554S   PAUSE~22cyc
  sm220u  (TBD)
"""

import geni.portal as portal
import geni.rspec.pg as pg
import geni.rspec.emulab as emulab

pc = portal.Context()
request = pc.makeRequestRSpec()

pc.defineParameter(
    "node_type", "Hardware Type",
    portal.ParameterType.NODETYPE, "c220g5",
    longDescription="Hardware type to allocate. All node types available on the "
                    "selected cluster are shown. Architecture is auto-detected by "
                    "setup_cloudlab.sh via /proc/cpuinfo.")

params = pc.bindParameters()
pc.verifyParameters()

hw_type = params.node_type

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
