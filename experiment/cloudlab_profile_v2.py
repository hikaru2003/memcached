"""
memcached PAUSE sweep - cross-architecture experiment profile

Single bare-metal node for measuring PAUSE latency characteristics per CPU
microarchitecture (Ivy Bridge, Broadwell, Skylake, Ice Lake, Emerald Rapids).

setup_cloudlab.sh (fetched from results branch) runs automatically at node startup:
  - Installs build dependencies (apt: build-essential, libevent, scons, numpy, ...)
  - Builds memcached        @ experiment/mysql-like-utdelay  -> memcached
  - Builds memcached_master @ master                         -> memcached_master
  - Builds memcached_wait_debug @ debug/wait-time            -> memcached_wait_debug
  - Builds mutilate_p999 (ConnectionStats.h patched for p50+p999)
  - Detects arch, generates ~/run_utdelay_experiment.sh (arch-specific CPU affinity)
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
"""

import geni.portal as portal
import geni.rspec.pg as pg

pc = portal.Context()
request = pc.makeRequestRSpec()

params = pc.bindParameters()
pc.verifyParameters()

# ---------------------------------------------------------------------------
# Node definition
# Hardware type and disk image are selected manually on CloudLab UI.
# ---------------------------------------------------------------------------
node = request.RawPC("node0")

# Ubuntu 24.04 (verified on all target arch nodes)
node.disk_image = "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU24-64-STD"

# ---------------------------------------------------------------------------
# Startup: auto-run setup_cloudlab.sh
# SETUP_URL encodes the branch: .../memcached/<branch>/experiment/setup_cloudlab.sh
# pg.Execute runs as root; setup_cloudlab.sh detects the experiment user automatically.
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
