#!/bin/bash
# Install Kata Containers on an existing kubeadm/containerd cluster with the kata-deploy Helm chart:
#   1. run check-prereqs.sh (unless --skip-checks)
#   2. fc shim only: set up an LVM thin pool and containerd's devmapper snapshotter on every target node
#   3. helm upgrade --install kata-deploy with the requested shims (first shim = default), wait for the rollout
#   4. smoke test: one busybox pod per kata-<shim> RuntimeClass, which must report a guest kernel, not the node's
# Idempotent: re-running upgrades the release and reuses an existing thin pool. The release's values are replaced by
# the ones this script generates plus any --values files; the previous values are saved first and differences shown.
#
# Usage: install-kata.sh [--shims "qemu-runtime-rs qemu fc"] [--version 4.2.0] [--nodes node1,node2]
#                        [--pool-gb 20 | --pool-device /dev/sdX] [--install-fc-tools] [--agent-timeout 45]
#                        [--values extra.yaml]... [--skip-checks] [--no-smoke-test] [--dry-run]
#   --nodes             install only on these nodes (labels them katacontainers.io/install=true and sets the chart's
#                       nodeSelector); default: every node without a NoSchedule/NoExecute taint
#   --pool-gb           fc: size of the sparse loop file backing the thin pool (default 20)
#   --pool-device       fc: an empty block device for the thin pool instead of a loop file (must carry no signatures)
#   --install-fc-tools  fc: install lvm2 and thin-provisioning-tools on the nodes (apt-get, dnf, yum or zypper)
#   --agent-timeout     seconds the runtime-rs shims wait for the guest agent (default 45, like the Go runtime;
#                       Kata's own 3 s is too short for nested VMs); 0 keeps Kata's default
#   --values            extra Helm values file, applied last (repeatable): keep custom settings here, since
#                       re-running this script does not reuse values set on the release by hand
#   --dry-run           print what would be done and change nothing
# Node access: through `kubectl debug node` pods, see DEBUG_NAMESPACE / DEBUG_IMAGE in lib.sh.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SHIMS="qemu-runtime-rs qemu"
VERSION="4.2.0"
NODES_ARG=""
POOL_GB=20
POOL_DEVICE=""
AGENT_TIMEOUT=45
EXTRA_VALUES=()
SKIP_CHECKS=0 SMOKE=1 DRY=0 FC_TOOLS=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --shims) SHIMS=$2; shift 2 ;;
    --version) VERSION=$2; shift 2 ;;
    --nodes) NODES_ARG=$2; shift 2 ;;
    --pool-gb) POOL_GB=$2; shift 2 ;;
    --pool-device) POOL_DEVICE=$2; shift 2 ;;
    --install-fc-tools) FC_TOOLS=1; shift ;;
    --agent-timeout) AGENT_TIMEOUT=$2; shift 2 ;;
    --values) [[ -f $2 ]] || die "--values: $2 not found"; EXTRA_VALUES+=(-f "$2"); shift 2 ;;
    --skip-checks) SKIP_CHECKS=1; shift ;;
    --no-smoke-test) SMOKE=0; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
read -ra SHIM_LIST <<<"$SHIMS"
[[ ${#SHIM_LIST[@]} -gt 0 ]] || die "--shims is empty"
[[ "$POOL_GB" =~ ^[0-9]+$ ]] || die "--pool-gb must be a number of GB"
[[ "$AGENT_TIMEOUT" =~ ^[0-9]+$ ]] || die "--agent-timeout must be a number of seconds"

# --- 1a. fc only: lvm2 and thin-provisioning-tools, before the checks that look for them ---
install_fc_tools() {  # install_fc_tools <node>: runs on the node as root
  node_bash "$1" <<'EOS'
set -eu
missing=""
for c in lvcreate thin_check losetup; do command -v $c >/dev/null || missing="$missing $c"; done
[ -z "$missing" ] && { echo "already installed"; exit 0; }
if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq lvm2 thin-provisioning-tools >/dev/null
elif command -v dnf >/dev/null; then dnf install -y -q lvm2 device-mapper-persistent-data
elif command -v yum >/dev/null; then yum install -y -q lvm2 device-mapper-persistent-data
elif command -v zypper >/dev/null; then zypper -q -n install lvm2 thin-provisioning-tools
else echo "no apt-get, dnf, yum or zypper: install lvm2 and thin-provisioning-tools by hand"; exit 1; fi
for c in lvcreate thin_check; do command -v $c >/dev/null || { echo "$c still missing after the install"; exit 1; }; done
echo "installed lvm2 and thin-provisioning-tools"
EOS
}
if has_shim fc && [[ $FC_TOOLS == 1 ]]; then
  load_target_nodes "$NODES_ARG"
  while read -r name; do
    if [[ $DRY == 1 ]]; then log "[dry-run] $name: would install lvm2 and thin-provisioning-tools if missing"; continue; fi
    out=$(install_fc_tools "$name" 2>&1) || die "$name: installing fc tools failed: $out"
    log "$name: $(tail -1 <<<"$out")"
  done <<<"$TARGETS"
fi

if [[ $SKIP_CHECKS == 0 ]]; then
  pool_arg=(--pool-gb "$POOL_GB"); [[ -z "$POOL_DEVICE" ]] || pool_arg=(--pool-device "$POOL_DEVICE")
  "$(dirname "$0")/check-prereqs.sh" --shims "$SHIMS" --version "$VERSION" "${pool_arg[@]}" ${NODES_ARG:+--nodes "$NODES_ARG"} \
    || die "prerequisite checks failed: fix the FAIL lines above, or pass --skip-checks"
  echo
fi
load_target_nodes "$NODES_ARG"
log "Target nodes: $(cut -d' ' -f1 <<<"$TARGETS" | paste -sd' ')"

# --- 2. devmapper snapshotter for the Firecracker shim ---
setup_devmapper() {  # setup_devmapper <node>: runs on the node as root; prints one status line, fails on error
  node_bash "$1" POOL_GB="$POOL_GB" POOL_DEVICE="'$POOL_DEVICE'" <<'EOS'
set -euo pipefail
modprobe dm_thin_pool 2>/dev/null || true
dmsetup targets | grep -qw thin-pool || { echo "kernel has no device-mapper thin provisioning"; exit 1; }
grep -Eq '^\s*imports\s*=.*conf\.d' /etc/containerd/config.toml || { echo "containerd config.toml has no conf.d import"; exit 1; }
mkdir -p /etc/containerd/conf.d
restart=0

# Without udev, LVM must create its /dev nodes itself, and containerd's devmapper snapshotter must not wait for udev
# (otherwise: "The file /dev/mapper/containerd-thinpool-snap-N does not exist" when it runs mkfs)
if ! systemctl is-active -q systemd-udevd 2>/dev/null; then
  sed -i -E 's/^(\s*)#\s*(udev_sync|udev_rules) = 1$/\1\2 = 0/' /etc/lvm/lvm.conf
  [ "$(lvmconfig --typeconfig full activation/udev_sync)" = "udev_sync=0" ] || { echo "could not set udev_sync = 0 in lvm.conf"; exit 1; }
  if [ ! -f /etc/systemd/system/containerd.service.d/dm-no-udev.conf ]; then
    mkdir -p /etc/systemd/system/containerd.service.d
    printf '[Service]\nEnvironment=DM_DISABLE_UDEV=1\n' >/etc/systemd/system/containerd.service.d/dm-no-udev.conf
    systemctl daemon-reload
    restart=1
  fi
fi

if ! vgs containerd >/dev/null 2>&1; then
  if [ -n "$POOL_DEVICE" ]; then
    [ -b "$POOL_DEVICE" ] || { echo "$POOL_DEVICE is not a block device"; exit 1; }
    [ -z "$(wipefs -n "$POOL_DEVICE")" ] || { echo "$POOL_DEVICE is not empty (wipefs shows signatures); refusing to use it"; exit 1; }
    pv=$POOL_DEVICE
  else
    # Loop file: a oneshot unit re-attaches it and activates the VG before containerd on every boot
    IMG=/var/lib/containerd-thinpool.img
    cat > /usr/local/sbin/containerd-thinpool-attach <<'EOF'
#!/bin/sh
set -e
losetup -j /var/lib/containerd-thinpool.img | grep -q . || losetup -f /var/lib/containerd-thinpool.img
vgchange -q -ay containerd
EOF
    chmod +x /usr/local/sbin/containerd-thinpool-attach
    cat > /etc/systemd/system/containerd-thinpool.service <<'EOF'
[Unit]
Description=Attach the loop-backed LVM thin pool for containerd's devmapper snapshotter
Before=containerd.service
ConditionPathExists=/var/lib/containerd-thinpool.img

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/containerd-thinpool-attach

[Install]
RequiredBy=containerd.service
EOF
    systemctl daemon-reload
    systemctl enable -q containerd-thinpool.service
    [ -f $IMG ] || truncate -s "${POOL_GB}G" $IMG
    pv=$(losetup -j $IMG | cut -d: -f1); [ -n "$pv" ] || pv=$(losetup -f --show $IMG)
  fi
  pvcreate -q "$pv"
  vgcreate -q containerd "$pv"
fi
vgchange -q -ay containerd >/dev/null
if ! lvs containerd/thinpool >/dev/null 2>&1; then
  lvcreate -q --wipesignatures y -n thinpool -l 95%VG containerd
  lvcreate -q --wipesignatures y -n thinpoolmeta -l 1%VG containerd
  lvconvert -q -y --zero n -c 512K --thinpool containerd/thinpool --poolmetadata containerd/thinpoolmeta
  mkdir -p /etc/lvm/profile
  printf 'activation {\n  thin_pool_autoextend_threshold=80\n  thin_pool_autoextend_percent=20\n}\n' \
    > /etc/lvm/profile/containerd-thinpool.profile
  lvchange -q --metadataprofile containerd-thinpool containerd/thinpool
fi

if [ ! -f /etc/containerd/conf.d/devmapper.toml ]; then
  cat > /etc/containerd/conf.d/devmapper.toml <<'EOF'
[plugins."io.containerd.snapshotter.v1.devmapper"]
pool_name = "containerd-thinpool"
root_path = "/var/lib/containerd/io.containerd.snapshotter.v1.devmapper"
base_image_size = "10GB"
discard_blocks = true
EOF
  restart=1
fi
if [ $restart = 1 ]; then systemctl restart containerd; sleep 3; fi
ctr plugins ls | grep -E 'snapshotter.*devmapper.*ok' >/dev/null || { echo "devmapper snapshotter not ok: $(ctr plugins ls | grep devmapper)"; exit 1; }
read -r size used <<<"$(lvs --noheadings -o lv_size,data_percent containerd/thinpool)"
echo "thin pool containerd/thinpool $size, ${used}% used; devmapper snapshotter ok"
EOS
}

if has_shim fc; then
  while read -r name; do
    if [[ $DRY == 1 ]]; then
      log "[dry-run] $name: would set up thin pool containerd/thinpool on ${POOL_DEVICE:-a ${POOL_GB}G loop file} and the devmapper snapshotter"
      continue
    fi
    log "$name: setting up thin pool and devmapper snapshotter"
    out=$(setup_devmapper "$name" 2>&1) || die "$name: devmapper setup failed: $out"
    log "$name: $(tail -1 <<<"$out")"
  done <<<"$TARGETS"
fi

# --- 3. kata-deploy ---
# Values go in a generated file (a TOML drop-in is multi-line, which --set handles badly)
VALUES=$(mktemp "${TMPDIR:-/tmp}/kata-deploy-values.XXXXXX.yaml")
trap 'rm -f "$VALUES"' EXIT
{
  echo "defaultShim:"
  echo "  amd64: ${SHIM_LIST[0]}"
  [[ -z "$NODES_ARG" ]] || printf 'nodeSelector:\n  katacontainers.io/install: "true"\n'
  echo "shims:"
  echo "  disableAll: true"
  for shim in "${SHIM_LIST[@]}"; do
    echo "  $shim:"
    echo "    enabled: true"
    if [[ $shim == *runtime-rs && $AGENT_TIMEOUT -gt 0 ]]; then
      # runtime-rs gives the guest agent reconnect_timeout_ms (3000) to come up; nested or busy nodes need longer
      printf '    dropIn: |\n      [agent.kata]\n      reconnect_timeout_ms = %d\n' $((AGENT_TIMEOUT * 1000))
    fi
  done
} >"$VALUES"
HELM_ARGS=(--version "$VERSION" --namespace kube-system -f "$VALUES" "${EXTRA_VALUES[@]}")

if [[ $DRY == 1 ]]; then
  [[ -z "$NODES_ARG" ]] || log "[dry-run] would label $(cut -d' ' -f1 <<<"$TARGETS" | paste -sd' ') katacontainers.io/install=true"
  log "[dry-run] generated Helm values:"; sed 's/^/    /' "$VALUES"
  log "[dry-run] would run: helm upgrade --install kata-deploy $CHART ${HELM_ARGS[*]} --wait --timeout 15m"
  log "[dry-run] then wait for the rollout and smoke test: $(printf 'kata-%s ' "${SHIM_LIST[@]}")"
  exit 0
fi

if [[ -n "$NODES_ARG" ]]; then
  while read -r name; do kubectl label node "$name" katacontainers.io/install=true --overwrite >/dev/null; done <<<"$TARGETS"
fi
if old=$(helm -n kube-system get values kata-deploy -o yaml 2>/dev/null) && [[ "$old" != "null" ]]; then
  backup="${TMPDIR:-/tmp}/kata-deploy-values.previous.$(date +%Y%m%d%H%M%S).yaml"
  printf '%s\n' "$old" >"$backup"
  log "Existing release: its values are saved in $backup and replaced by this run's (generated + --values)"
  diff <(helm template kata-deploy "$CHART" --version "$VERSION" --namespace kube-system -f "$backup" 2>&1) \
       <(helm template kata-deploy "$CHART" "${HELM_ARGS[@]}" 2>&1) >/dev/null \
    || log "WARNING: the new values render differently from the release's; if it carried hand-made settings, pass them with --values $backup"
fi
log "Installing kata-deploy $VERSION with shims: $SHIMS (default ${SHIM_LIST[0]})"
helm upgrade --install kata-deploy "$CHART" "${HELM_ARGS[@]}" --wait --timeout 15m

# kata-deploy restarts containerd on every node it touches; sandboxes created in that window fail
# (EOF / "tun set iff: EBUSY" / "failed to set up network"), so wait for the DaemonSet and let containerd settle
kubectl -n kube-system rollout status ds/kata-deploy --timeout=10m
sleep 20
log "Waiting for RuntimeClasses and node labels"
for _ in $(seq 1 60); do
  ready=1
  for shim in "${SHIM_LIST[@]}"; do kubectl get runtimeclass "kata-$shim" >/dev/null 2>&1 || ready=0; done
  while read -r name; do
    [[ "$(kubectl get node "$name" -o jsonpath='{.metadata.labels.katacontainers\.io/kata-runtime}')" == true ]] || ready=0
  done <<<"$TARGETS"
  [[ $ready == 1 ]] && break
  sleep 5
done
[[ $ready == 1 ]] || die "RuntimeClasses or node labels did not appear (kubectl -n kube-system logs ds/kata-deploy)"
kubectl get runtimeclass
kubectl get nodes -L katacontainers.io/kata-runtime

# --- 4. smoke test ---
[[ $SMOKE == 1 ]] || { log "Kata installed (smoke test skipped)"; exit 0; }
failed=()
for shim in "${SHIM_LIST[@]}"; do
  rc="kata-$shim" pod="kata-smoke-$shim"
  log "Smoke test: $pod (runtimeClassName: $rc)"
  kubectl delete pod "$pod" --ignore-not-found --wait >/dev/null
  kubectl run "$pod" --image=busybox:1.36 --restart=Never \
    --overrides="{\"spec\":{\"runtimeClassName\":\"$rc\"}}" -- sleep 300 >/dev/null
  if ! kubectl wait --for=condition=Ready "pod/$pod" --timeout=300s >/dev/null; then
    kubectl describe pod "$pod" | sed -n '/^Events:/,$p' | tail -8
    failed+=("$rc"); kubectl delete pod "$pod" --wait=false >/dev/null; continue
  fi
  node=$(kubectl get pod "$pod" -o jsonpath='{.spec.nodeName}')
  pod_kernel=$(kubectl exec "$pod" -- uname -r)
  node_kernel=$(kubectl get node "$node" -o jsonpath='{.status.nodeInfo.kernelVersion}')
  if [[ "$pod_kernel" != "$node_kernel" ]]; then
    log "  OK on $node: guest kernel $pod_kernel (node kernel $node_kernel)"
  else
    log "  FAIL on $node: pod reports the node's own kernel $node_kernel, so it is not in a Kata VM"
    failed+=("$rc")
  fi
  kubectl delete pod "$pod" --wait=false >/dev/null
done
[[ ${#failed[@]} -eq 0 ]] || die "smoke test failed for: ${failed[*]}"
log "Kata is installed and working: $(printf 'kata-%s ' "${SHIM_LIST[@]}")"
