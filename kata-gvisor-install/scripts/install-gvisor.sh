#!/bin/bash
# Install gVisor (runsc) on an existing kubeadm/containerd cluster:
#   1. run check-prereqs.sh --runtimes gvisor (unless --skip-checks): arch, containerd, conf.d import, runsc download,
#      /dev/kvm for kvm
#   2. install runsc, containerd-shim-runsc-v1 and (newer releases) gvisor-bin/ into /usr/local/bin from the gVisor release tarball (the node's curl/wget
#      downloads it and checks its sha512; the debug image's busybox tar unpacks it, since nodes often lack bzip2).
#      A runsc already installed elsewhere (e.g. the distro/apt package in /usr/bin) is kept and used instead.
#   3. write /etc/containerd/conf.d/gvisor.toml with one handler per platform (adding the conf.d import to config.toml if
#      it has none; a backup is kept), restart containerd if anything changed
#   4. label the nodes runtime.gvisor=true and create the RuntimeClasses (scheduled onto those nodes)
#   5. smoke test: one busybox pod per RuntimeClass, which must boot gVisor on the requested platform
# Platforms: systrap -> handler runsc, RuntimeClass gvisor; kvm -> handler runsc-kvm, RuntimeClass gvisor-kvm (needs /dev/kvm).
# Idempotent: re-running changes nothing that is already in place. Handlers are only ever added, never removed.
#
# Usage: install-gvisor.sh [--platforms "systrap kvm"] [--version latest|20261012.0] [--nodes node1,node2]
#                          [--url-base URL] [--skip-checks] [--no-smoke-test] [--dry-run]
#   --platforms  default "systrap" (works everywhere); add kvm on nodes with (nested) virtualisation
#   --version    gVisor release, as in runsc --version without "release-" (default latest)
#   --nodes      install only on these nodes; default: every node without a NoSchedule/NoExecute taint
#   --url-base   release mirror (default https://storage.googleapis.com/gvisor/releases/release); fetches
#                <url-base>/<version>/<x86_64|aarch64>/gvisor.tar.bz2 and .sha512
#   --dry-run    run the checks, print what would be done and change nothing
# Node access: through `kubectl debug node` pods, see DEBUG_NAMESPACE / DEBUG_IMAGE in lib.sh (DEBUG_IMAGE must provide a
# tar that can unpack .bz2, as busybox does). Restarting containerd leaves running containers alone, but pods being
# created at that moment can fail once and be retried by the kubelet.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

PLATFORMS="systrap"
VERSION="latest"
NODES_ARG=""
URL_BASE="https://storage.googleapis.com/gvisor/releases/release"
SKIP_CHECKS=0 SMOKE=1 DRY=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --platforms) PLATFORMS=$2; shift 2 ;;
    --version) VERSION=${2#release-}; shift 2 ;;
    --nodes) NODES_ARG=$2; shift 2 ;;
    --url-base) URL_BASE=${2%/}; shift 2 ;;
    --skip-checks) SKIP_CHECKS=1; shift ;;
    --no-smoke-test) SMOKE=0; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
read -ra PLAT_LIST <<<"$PLATFORMS"
[[ ${#PLAT_LIST[@]} -gt 0 ]] || die "--platforms is empty"
for p in "${PLAT_LIST[@]}"; do [[ $p == systrap || $p == kvm ]] || die "unknown platform $p (systrap, kvm)"; done
handler_of() { [[ $1 == kvm ]] && echo runsc-kvm || echo runsc; }
rc_of() { [[ $1 == kvm ]] && echo gvisor-kvm || echo gvisor; }

if [[ $SKIP_CHECKS == 0 ]]; then
  "$(dirname "$0")/check-prereqs.sh" --runtimes gvisor --platforms "$PLATFORMS" --gvisor-version "$VERSION" \
    --url-base "$URL_BASE" ${NODES_ARG:+--nodes "$NODES_ARG"} \
    || die "prerequisite checks failed: fix the FAIL lines above, or pass --skip-checks"
  echo
fi
load_target_nodes "$NODES_ARG"
log "Target nodes: $(paste -sd' ' <<<"$TARGETS"); platforms: $PLATFORMS; gVisor $VERSION"

if [[ $DRY == 1 ]]; then
  log "[dry-run] would install runsc $VERSION in /usr/local/bin where no other runsc is installed"
  log "[dry-run] would write /etc/containerd/conf.d/gvisor.toml with handlers: $(for p in "${PLAT_LIST[@]}"; do handler_of "$p"; done | paste -sd' ') (plus any it already has), restarting containerd if it changes"
  log "[dry-run] would label $(paste -sd' ' <<<"$TARGETS") runtime.gvisor=true, create RuntimeClasses $(for p in "${PLAT_LIST[@]}"; do rc_of "$p"; done | paste -sd' ') and smoke test them"
  exit 0
fi

# --- 2. binaries ---
install_binaries() {  # install_binaries <node>: runs in the debug image (busybox), the node's / at /host
  NODE_CHROOT=0 node_bash "$1" URL="'$URL_BASE/$VERSION'" <<'EOS'
set -eu
H=/host
existing=$(chroot $H sh -c 'command -v runsc' 2>/dev/null || true)
if [ -n "$existing" ] && [ "$existing" != /usr/local/bin/runsc ]; then
  echo "keeping $existing: $(chroot $H runsc --version | head -1)"; exit 0
fi
arch=$(chroot $H uname -m)
tmp=$(chroot $H mktemp -d /var/tmp/gvisor-install.XXXXXX)
trap 'rm -rf "$H$tmp"' EXIT
# download and verify with the node's own tools (busybox wget does not validate TLS certificates)
if chroot $H sh -c 'command -v curl' >/dev/null; then fetch="curl -fsSL --retry 3 -o"; else fetch="wget -q -O"; fi
for f in gvisor.tar.bz2 gvisor.tar.bz2.sha512; do
  chroot $H $fetch "$tmp/$f" "$URL/$arch/$f" || { echo "download of $URL/$arch/$f failed"; exit 1; }
done
chroot $H sh -c "cd $tmp && sha512sum -c gvisor.tar.bz2.sha512" >/dev/null || { echo "sha512 mismatch for gvisor.tar.bz2"; exit 1; }
cd "$H$tmp"
tar xjf gvisor.tar.bz2 \
  || { echo "could not unpack gvisor.tar.bz2 with the debug image's tar (DEBUG_IMAGE needs bzip2 support, as busybox has)"; exit 1; }
[ -f runsc ] && [ -f containerd-shim-runsc-v1 ] || { echo "gvisor.tar.bz2 lacks runsc or containerd-shim-runsc-v1"; exit 1; }
# newer releases split the sentry and helpers into gvisor-bin/, which runsc looks for next to itself
files="runsc containerd-shim-runsc-v1"
[ -d gvisor-bin ] && files="$files $(find gvisor-bin -type f | sort | tr '\n' ' ')"
mkdir -p $H/usr/local/bin/gvisor-bin
updated=""
for f in $files; do
  dst=$H/usr/local/bin/$f
  if ! cmp -s "$f" "$dst"; then
    cp "$f" "$dst.new" && chmod 755 "$dst.new" && mv -f "$dst.new" "$dst"   # rename: running shims keep the old file
    updated="$updated $f"
  fi
done
echo "$(chroot $H /usr/local/bin/runsc --version | head -1) in /usr/local/bin${updated:+ (installed:$updated)}"
EOS
}

# --- 3. containerd handlers ---
configure_containerd() {  # configure_containerd <node>: runs on the node as root; last line is a status summary
  node_bash "$1" PLATFORMS="'$PLATFORMS'" <<'EOS'
set -euo pipefail
cfg=/etc/containerd/config.toml dropin=/etc/containerd/conf.d/gvisor.toml
ver=$(containerd --version | awk '{print $3}'); ver=${ver#v}
if [ "${ver%%.*}" -ge 2 ]; then cri=io.containerd.cri.v1.runtime cfgver=3; else cri=io.containerd.grpc.v1.cri cfgver=2; fi
restart=0 notes=""

put() {  # put <file> <content>: write the file if its content differs; returns 1 if unchanged
  [ -f "$1" ] && [ "$(cat "$1")" = "$2" ] && return 1
  printf '%s\n' "$2" >"$1"
}

# Handlers an earlier run (or scripts/05) added stay, so their RuntimeClasses keep working
handlers=""
for p in systrap kvm; do
  h=runsc; [ $p = kvm ] && h=runsc-kvm
  if case " $PLATFORMS " in *" $p "*) true ;; *) false ;; esac; then handlers="$handlers $h"
  elif [ -f $dropin ] && grep -q "runtimes\.$h\]" $dropin; then handlers="$handlers $h"; notes="$notes; kept $h"; fi
done

mkdir -p /etc/containerd/conf.d /etc/containerd/runsc
content=""
for h in $handlers; do
  content+="[plugins.\"$cri\".containerd.runtimes.$h]
runtime_type = \"io.containerd.runsc.v1\"
"
  if [ $h = runsc-kvm ]; then
    content+="
[plugins.\"$cri\".containerd.runtimes.$h.options]
TypeUrl = \"io.containerd.runsc.v1.options\"
ConfigPath = \"/etc/containerd/runsc/runsc-kvm.toml\"
"
    put /etc/containerd/runsc/runsc-kvm.toml '[runsc_config]
  platform = "kvm"' || true   # read by the shim at sandbox start, no restart needed
  fi
  content+="
"
done
put $dropin "$(printf '%s' "$content")" && restart=1   # $(...) drops the trailing blank lines

if [ ! -f $cfg ]; then
  printf 'version = %s\nimports = ["/etc/containerd/conf.d/*.toml"]\n' $cfgver >$cfg
  restart=1 notes="$notes; created $cfg"
elif ! grep -Eq '^\s*imports\s*=.*conf\.d' $cfg; then
  grep -Eq '^\s*imports\s*=' $cfg && { echo "$cfg has an imports line without conf.d"; exit 1; }
  bak=$cfg.bak-gvisor-$(date +%Y%m%d%H%M%S)
  cp -p $cfg "$bak"
  if grep -Eq '^version\s*=' $cfg; then sed -i -E '0,/^version\s*=.*/s##&\nimports = ["/etc/containerd/conf.d/*.toml"]#' $cfg
  else sed -i '1i imports = ["/etc/containerd/conf.d/*.toml"]' $cfg; fi
  restart=1 notes="$notes; added conf.d import to $cfg (backup $bak)"
fi

if [ $restart = 1 ]; then
  systemctl restart containerd
  for _ in $(seq 1 30); do ctr version >/dev/null 2>&1 && break; sleep 1; done
fi
systemctl is-active -q containerd || { echo "containerd is not active after the restart: journalctl -u containerd"; exit 1; }
dump=$(containerd config dump 2>&1)
for h in $handlers; do
  grep -Eq "runtimes\.$h\]" <<<"$dump" || { echo "containerd config dump has no $h handler"; exit 1; }
done
echo "handlers:$handlers; containerd $([ $restart = 1 ] && echo restarted || echo unchanged)$notes"
EOS
}

restarted=0
while read -r name; do
  log "$name: installing runsc"
  out=$(install_binaries "$name" 2>&1) || die "$name: runsc install failed: $out"
  log "$name: $(tail -1 <<<"$out")"
  out=$(configure_containerd "$name" 2>&1) || die "$name: containerd configuration failed: $out"
  log "$name: $(tail -1 <<<"$out")"
  [[ "$out" == *"containerd restarted"* ]] && restarted=1
  kubectl label node "$name" runtime.gvisor=true --overwrite >/dev/null
done <<<"$TARGETS"
# sandboxes created right after a containerd restart can fail, so give it a moment before the smoke test
[[ $restarted == 0 ]] || sleep 10

# --- 4. RuntimeClasses ---
for p in "${PLAT_LIST[@]}"; do
  kubectl apply -f - >/dev/null <<EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: $(rc_of "$p")
handler: $(handler_of "$p")
scheduling:
  nodeSelector:
    runtime.gvisor: "true"
EOF
done
kubectl get runtimeclass
kubectl get nodes -L runtime.gvisor

# --- 5. smoke test ---
[[ $SMOKE == 1 ]] || { log "gVisor installed (smoke test skipped)"; exit 0; }
failed=()
for p in "${PLAT_LIST[@]}"; do
  rc=$(rc_of "$p") pod="gvisor-smoke-$(rc_of "$p")"
  log "Smoke test: $pod (runtimeClassName: $rc)"
  kubectl delete pod "$pod" --ignore-not-found --wait >/dev/null
  kubectl run "$pod" --image=busybox:1.36 --restart=Never \
    --overrides="{\"spec\":{\"runtimeClassName\":\"$rc\"}}" -- sleep 300 >/dev/null
  if ! kubectl wait --for=condition=Ready "pod/$pod" --timeout=180s >/dev/null; then
    kubectl describe pod "$pod" | sed -n '/^Events:/,$p' | tail -8
    failed+=("$rc"); kubectl delete pod "$pod" --wait=false >/dev/null; continue
  fi
  node=$(kubectl get pod "$pod" -o jsonpath='{.spec.nodeName}')
  uid=$(kubectl get pod "$pod" -o jsonpath='{.metadata.uid}')
  boot=$(kubectl exec "$pod" -- dmesg 2>&1 | head -1)
  # the sandbox's runsc processes carry the pod UID (in --panic-log) and the platform flag
  plat=$(node_bash "$node" UID_="$uid" <<'EOS' 2>&1 | tail -1
procs=$(pgrep -a runsc | grep -- "_${UID_}/")
[ -n "$procs" ] || { echo none; exit 0; }
plat=$(grep -o -- '--platform=[a-z]*' <<<"$procs" | sort -u | cut -d= -f2 | paste -sd' ')
echo "${plat:-default}"
EOS
  )
  if [[ "$boot" != *gVisor* ]]; then
    log "  FAIL on $node: dmesg shows '$boot', not a gVisor boot"; failed+=("$rc")
  elif [[ "$plat" != "$p" && ! ( $p == systrap && "$plat" == default ) ]]; then
    log "  FAIL on $node: sandbox runs with platform '$plat', expected $p"; failed+=("$rc")
  else
    log "  OK on $node: '$boot', platform $plat"
  fi
  kubectl delete pod "$pod" --wait=false >/dev/null
done
[[ ${#failed[@]} -eq 0 ]] || die "smoke test failed for: ${failed[*]}"
log "gVisor is installed and working: $(for p in "${PLAT_LIST[@]}"; do rc_of "$p"; done | paste -sd' ')"
