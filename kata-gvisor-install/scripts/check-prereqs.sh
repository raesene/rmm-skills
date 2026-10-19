#!/bin/bash
# Readiness check for installing Kata Containers (kata-deploy) and/or gVisor on an existing kubeadm/containerd cluster.
# Checks this machine (kubectl, helm, cluster access, chart) and, through a short-lived `kubectl debug node` pod, every
# target node (Kata: KVM, vsock, containerd, and the devmapper prerequisites when the fc shim is requested; gVisor:
# containerd, conf.d import, runsc download, /dev/kvm for the kvm platform). Changes nothing on the nodes. Exits 1 if any
# check FAILs.
#
# Usage: check-prereqs.sh [--runtimes kata,gvisor] [--nodes node1,node2]
#                         [--shims "qemu-runtime-rs qemu fc"] [--version 4.2.0] [--pool-gb 20]          (Kata)
#                         [--platforms "systrap kvm"] [--gvisor-version latest] [--url-base URL]         (gVisor)
#   --runtimes  which installs to check for: kata (default), gvisor, or kata,gvisor
#   other options as in install-kata.sh and install-gvisor.sh (whose --version is --gvisor-version here)
# Node access: see DEBUG_NAMESPACE / DEBUG_IMAGE in lib.sh.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

RUNTIMES="kata"
SHIMS="qemu-runtime-rs qemu"
VERSION="4.2.0"
PLATFORMS="systrap"
GVISOR_VERSION="latest"
URL_BASE="https://storage.googleapis.com/gvisor/releases/release"
NODES_ARG=""
POOL_GB=20
while [[ $# -gt 0 ]]; do
  case $1 in
    --runtimes) RUNTIMES=$2; shift 2 ;;
    --shims) SHIMS=$2; shift 2 ;;
    --version) VERSION=$2; shift 2 ;;
    --platforms) PLATFORMS=$2; shift 2 ;;
    --gvisor-version) GVISOR_VERSION=${2#release-}; shift 2 ;;
    --url-base) URL_BASE=${2%/}; shift 2 ;;
    --nodes) NODES_ARG=$2; shift 2 ;;
    --pool-gb) POOL_GB=$2; shift 2 ;;
    --pool-device) POOL_GB=0; shift 2 ;;   # no loop file, so no space check
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
RUNTIMES=${RUNTIMES// /,}
for r in ${RUNTIMES//,/ }; do [[ $r == kata || $r == gvisor ]] || die "unknown runtime $r (kata, gvisor)"; done
for p in $PLATFORMS; do [[ $p == systrap || $p == kvm ]] || die "unknown gVisor platform $p (systrap, kvm)"; done
has_rt() { [[ ",$RUNTIMES," == *",$1,"* ]]; }

FAILS=0 WARNS=0
report() {  # report <PASS|WARN|FAIL|INFO> <where> <check> <detail>
  case $1 in FAIL) FAILS=$((FAILS + 1)) ;; WARN) WARNS=$((WARNS + 1)) ;; esac
  printf '%-4s  %-24s  %-16s  %s\n' "$1" "$2" "$3" "$4"
}

what=()
has_rt kata && what+=("Kata $VERSION, shims: $SHIMS")
has_rt gvisor && what+=("gVisor $GVISOR_VERSION, platforms: $PLATFORMS")
echo "Checking prerequisites for $(printf '%s; ' "${what[@]}" | sed 's/; $//')"
printf '%-4s  %-24s  %-16s  %s\n' RES WHERE CHECK DETAIL

# --- this machine and the cluster API ---
tools=(kubectl); has_rt kata && tools+=(helm)
for tool in "${tools[@]}"; do
  command -v $tool >/dev/null && report PASS local $tool "$(command -v $tool)" || report FAIL local $tool "not installed"
done
if has_rt kata; then
  command -v helm >/dev/null || { echo "helm missing, stopping"; exit 1; }
  hv=$(helm version --template '{{.Version}}' 2>/dev/null)
  [[ "$hv" =~ ^v(3\.([89]|[1-9][0-9])|[4-9])\. ]] && report PASS local helm-version "$hv" \
    || report FAIL local helm-version "$hv (need >= 3.8 for OCI charts)"
fi

if ! kubectl get --raw /readyz >/dev/null 2>&1; then
  report FAIL local cluster-api "cannot reach the API server with the current KUBECONFIG/context"
  echo; echo "$FAILS failed, $WARNS warnings"; exit 1
fi
report PASS local cluster-api "$(kubectl config current-context 2>/dev/null)"
missing=""
perms=("create runtimeclasses.node.k8s.io" "patch nodes" "get nodes" "create pods" "create pods -n $DEBUG_NAMESPACE"
       "get pods/log -n $DEBUG_NAMESPACE" "delete pods -n $DEBUG_NAMESPACE")
has_rt kata && perms+=("create daemonsets -n kube-system" "create clusterroles" "create clusterrolebindings")
for perm in "${perms[@]}"; do
  kubectl auth can-i $perm >/dev/null 2>&1 || missing+="${missing:+, }$perm"
done
[[ -z "$missing" ]] && report PASS local permissions "can install the runtimes and run node debug pods" \
  || report FAIL local permissions "missing: $missing (needs cluster-admin)"
kubectl debug --help 2>/dev/null | grep -q -- '--profile=' && report PASS local kubectl-debug "supports --profile=sysadmin" \
  || report FAIL local kubectl-debug "kubectl $(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion": *"[^"]*"' | cut -d'"' -f4) has no 'debug --profile' (need >= 1.27)"
if ! psa=$(kubectl get ns "$DEBUG_NAMESPACE" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null); then
  report FAIL local debug-ns "namespace $DEBUG_NAMESPACE not found (set DEBUG_NAMESPACE)"
elif [[ -z "$psa" || "$psa" == privileged ]]; then
  report PASS local debug-ns "$DEBUG_NAMESPACE allows privileged debug pods"
else
  report FAIL local debug-ns "$DEBUG_NAMESPACE enforces Pod Security '$psa'; privileged debug pods will be rejected (set DEBUG_NAMESPACE)"
fi
if has_rt kata; then
  helm show chart "$CHART" --version "$VERSION" >/dev/null 2>&1 && report PASS local chart "kata-deploy $VERSION reachable" \
    || report FAIL local chart "cannot fetch $CHART --version $VERSION"
  if rel=$(helm -n kube-system list -f '^kata-deploy$' -o json 2>/dev/null) && [[ "$rel" != "[]" ]]; then
    report INFO local release "kata-deploy already installed: $(grep -o '"chart":"[^"]*"' <<<"$rel" | cut -d'"' -f4) (install will upgrade it)"
  fi
fi

# --- nodes ---
load_target_nodes "$NODES_ARG"
while read -r name; do
  runtime=$(kubectl get node "$name" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}')
  [[ "$runtime" == containerd://* ]] && report PASS "$name" runtime "$runtime" \
    || report FAIL "$name" runtime "$runtime (these scripts support containerd only)"
  if ! out=$(node_bash "$name" RUNTIMES="'$RUNTIMES'" SHIMS="'$SHIMS'" PLATFORMS="'$PLATFORMS'" POOL_GB="$POOL_GB" GURL="'$URL_BASE/$GVISOR_VERSION'" <<'EOS' 2>&1
set -u
res() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
has_rt() { case ",$RUNTIMES," in *",$1,"*) return 0 ;; esac; return 1; }
has_shim() { has_rt kata && case " $SHIMS " in *" $1 "*) return 0 ;; esac; return 1; }
has_plat() { has_rt gvisor && case " $PLATFORMS " in *" $1 "*) return 0 ;; esac; return 1; }
# a device node, or a kernel module that can provide it (modprobe -n loads nothing)
dev_or_mod() { [ -c "$1" ] && echo "$1 present" && return 0
               modprobe -n -q "$2" 2>/dev/null && echo "module $2 available (kata-deploy loads it)" && return 0; return 1; }

arch=$(uname -m)
if has_rt kata; then
  [ "$arch" = x86_64 ] && res PASS arch "$arch" || res FAIL arch "$arch (install-kata.sh sets the amd64 default shim only)"
else
  case $arch in x86_64|aarch64) res PASS arch "$arch" ;; *) res FAIL arch "$arch (gVisor supports x86_64 and aarch64)" ;; esac
fi

virt=$(systemd-detect-virt 2>/dev/null || true)
if has_rt kata && [ -n "$virt" ] && [ "$virt" != none ]; then
  res INFO nested "node is a VM ($virt): Kata guests are nested and boot slower (install-kata.sh raises runtime-rs's agent timeout, see --agent-timeout)"
fi

if has_rt kata || has_plat kvm; then
  hint="enable (nested) virtualisation for this machine"; has_rt kata || hint="$hint, or pass --platforms systrap"
  if [ -c /dev/kvm ]; then res PASS kvm "/dev/kvm present"
  elif grep -qwE 'vmx|svm' /proc/cpuinfo; then res FAIL kvm "no /dev/kvm, but the CPU has vmx/svm: load kvm_intel or kvm_amd"
  else res FAIL kvm "no /dev/kvm and no vmx/svm CPU flag: $hint"; fi
fi

if has_rt kata; then
  d=$(dev_or_mod /dev/vhost-vsock vhost_vsock) && res PASS vhost-vsock "$d" \
    || res FAIL vhost-vsock "no /dev/vhost-vsock or vhost_vsock module (Kata's agent channel)"
  d=$(dev_or_mod /dev/vhost-net vhost_net) && res PASS vhost-net "$d" \
    || res WARN vhost-net "no /dev/vhost-net or vhost_net module (slower guest networking)"
fi

if ! command -v systemctl >/dev/null; then res FAIL systemd "no systemctl (the installs restart containerd through systemd)"
elif systemctl is-active -q containerd; then
  ver=$(containerd --version | awk '{print $3}'); ver=${ver#v}
  major=${ver%%.*}; minor=${ver#*.}; minor=${minor%%.*}
  want=6; has_rt kata && want=7
  if [ "$major" -ge 2 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge $want ]; }; then res PASS containerd "$ver, active"
  else res WARN containerd "$ver: Kata 4.x is tested with containerd >= 1.7, gVisor here with >= 1.6"; fi
else res FAIL containerd "containerd.service not active"; fi

cfg=/etc/containerd/config.toml
if [ ! -f $cfg ]; then
  if has_rt gvisor; then res INFO containerd-cfg "no $cfg: install-gvisor.sh creates one with only the conf.d import"
  else res WARN containerd-cfg "no $cfg (generate one: containerd config default > $cfg)"; fi
elif grep -Eq '^\s*imports\s*=.*conf\.d' $cfg; then res PASS containerd-cfg "$cfg imports conf.d"
elif has_rt gvisor && grep -Eq '^\s*imports\s*=' $cfg; then
  res FAIL containerd-cfg "$cfg has an imports line without conf.d: add \"/etc/containerd/conf.d/*.toml\" to it"
elif has_rt gvisor; then res INFO containerd-cfg "$cfg has no conf.d import: install-gvisor.sh adds it (backup kept)"
elif has_shim fc; then res FAIL containerd-cfg "$cfg has no conf.d import (add: imports = [\"/etc/containerd/conf.d/*.toml\"])"
else res INFO containerd-cfg "$cfg has no conf.d import (only needed for the fc shim)"; fi

if has_rt kata; then
  avail=$(df --output=avail -BG /opt 2>/dev/null | tail -1 | tr -dc 0-9)
  [ "${avail:-0}" -ge 2 ] && res PASS disk "${avail}G free for /opt/kata" || res WARN disk "${avail:-?}G free for /opt/kata (want >= 2G)"
  mem=$(awk '/MemTotal/ {print int($2/1048576)}' /proc/meminfo)
  [ "$mem" -ge 4 ] && res PASS memory "${mem}G" || res WARN memory "${mem}G (each Kata pod boots a VM with 2G by default)"
  [ -d /opt/kata ] && res INFO kata "already present in /opt/kata"
fi

if has_shim fc; then
  # built in (=y) is invisible to modprobe -n, and dmsetup may not be installed yet, so also look at sysfs and the config
  kcfg=$( { zcat /proc/config.gz 2>/dev/null || cat "/boot/config-$(uname -r)" 2>/dev/null; } | grep -E '^CONFIG_DM_THIN_PROVISIONING=' )
  if [ -e /dev/mapper/control ] && { dmsetup targets 2>/dev/null | grep -qw thin-pool || [ -d /sys/module/dm_thin_pool ] \
       || modprobe -n -q dm_thin_pool 2>/dev/null || [ -n "$kcfg" ]; }
  then res PASS dm-thin "device-mapper thin provisioning available${kcfg:+ ($kcfg)}"
  else res FAIL dm-thin "kernel lacks device-mapper thin provisioning (CONFIG_DM_THIN_PROVISIONING)"; fi
  missing=""
  for c in lvcreate thin_check losetup; do command -v $c >/dev/null || missing="$missing $c"; done
  [ -z "$missing" ] && res PASS fc-tools "lvm2, thin-provisioning-tools, losetup" \
    || res FAIL fc-tools "missing:$missing (install-kata.sh --install-fc-tools installs lvm2 and thin-provisioning-tools)"
  if [ "$POOL_GB" -gt 0 ] && ! [ -f /var/lib/containerd-thinpool.img ]; then
    free=$(df --output=avail -BG /var/lib 2>/dev/null | tail -1 | tr -dc 0-9)
    [ "${free:-0}" -gt "$POOL_GB" ] && res PASS pool-space "${free}G free in /var/lib for the ${POOL_GB}G thin pool file" \
      || res WARN pool-space "${free:-?}G free in /var/lib, pool file is ${POOL_GB}G (sparse, but can fill the disk): lower --pool-gb"
  fi
  if command -v lvs >/dev/null && lvs containerd/thinpool >/dev/null 2>&1; then res INFO thinpool "containerd/thinpool exists (reused)"; fi
  systemctl is-active -q systemd-udevd 2>/dev/null || res INFO udev "no udev: install-kata.sh configures LVM/devmapper to work without it"
fi

if has_rt gvisor; then
  [ -f /etc/containerd/conf.d/gvisor.toml ] && \
    res INFO handlers "existing gvisor.toml: $(grep -o 'runtimes\.runsc[a-z-]*\]' /etc/containerd/conf.d/gvisor.toml | tr -d ']' | sed 's/runtimes\.//' | paste -sd' ') (kept)"
  existing=$(command -v runsc || true)
  if [ -n "$existing" ] && [ "$existing" != /usr/local/bin/runsc ]; then
    res INFO runsc "keeping $existing ($(runsc --version 2>/dev/null | head -1)); --version does not apply to it"
    command -v containerd-shim-runsc-v1 >/dev/null || res FAIL runsc "$existing has no containerd-shim-runsc-v1 next to it on PATH"
  else
    [ -n "$existing" ] && res INFO runsc "installed: $(runsc --version 2>/dev/null | head -1)"
    if command -v curl >/dev/null; then fetch="curl -fsSI"; tool=curl
    elif command -v wget >/dev/null; then fetch="wget -q --spider"; tool=wget
    else fetch=""; res FAIL download "no curl or wget on the node"; fi
    command -v sha512sum >/dev/null || res FAIL download "no sha512sum on the node"
    if [ -n "$fetch" ]; then
      url="$GURL/$arch/gvisor.tar.bz2"
      $fetch "$url" >/dev/null 2>&1 && res PASS download "$url reachable ($tool)" \
        || res FAIL download "cannot fetch $url (wrong --version, or no egress: see --url-base)"
    fi
  fi
fi
EOS
  ); then
    report FAIL "$name" node-access "cannot run checks in a debug pod: $(tail -1 <<<"$out")"
    continue
  fi
  while IFS=$'\t' read -r level check detail; do
    [[ "$level" =~ ^(PASS|WARN|FAIL|INFO)$ ]] && report "$level" "$name" "$check" "$detail"
  done <<<"$out"
done <<<"$TARGETS"

echo
echo "$FAILS failed, $WARNS warnings"
[[ $FAILS -eq 0 ]]
