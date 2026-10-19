# Shared helpers for check-prereqs.sh, install-kata.sh and install-gvisor.sh. Works against any kubeadm-style cluster that runs containerd.
# Only Kubernetes API access is needed (current KUBECONFIG/context): commands run on nodes through `kubectl debug node/...`
# pods (sysadmin profile: privileged, host namespaces, the node's / mounted at /host, which they chroot into).
#
# Environment:
#   DEBUG_NAMESPACE  namespace for the node debug pods (default: kube-system); Pod Security must allow privileged pods
#   DEBUG_IMAGE      image for the debug pods (default: busybox:1.36); only provides `chroot`, so any small image will do
#   NODE_TIMEOUT     seconds to wait for one node command, including the image pull (default: 300)

DEBUG_NAMESPACE="${DEBUG_NAMESPACE:-kube-system}"
DEBUG_IMAGE="${DEBUG_IMAGE:-busybox:1.36}"
NODE_TIMEOUT="${NODE_TIMEOUT:-300}"
CHART="oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# node_bash <node> [VAR=value ...]: run the bash script on stdin as root on the node; prints its output, returns its exit code.
# kubectl debug -i does not reliably deliver piped stdin, so the script is passed as an argument, and the output and exit
# code are read back from the finished pod, which is then deleted.
# With NODE_CHROOT=0 the script runs under the debug image's own sh instead (the node's / is still mounted at /host), for
# tools the node may lack, such as busybox's tar -j.
node_bash() {
  local node=$1; shift
  local script="" kv out pod phase="" reason="" rc i cmd=(chroot /host bash -c)
  [[ "${NODE_CHROOT:-1}" == 1 ]] || cmd=(sh -c)
  for kv in "$@"; do script+="export $kv; "; done   # values must already be shell-quoted
  script+=$(cat)
  out=$(kubectl debug "node/$node" -n "$DEBUG_NAMESPACE" --profile=sysadmin --image="$DEBUG_IMAGE" \
        -- "${cmd[@]}" "$script" 2>&1) || { echo "kubectl debug failed: $out"; return 1; }
  pod=$(grep -o 'node-debugger-[^ ]*' <<<"$out" | head -1)
  [[ -n "$pod" ]] || { echo "kubectl debug did not report a pod: $out"; return 1; }
  trap "kubectl -n '$DEBUG_NAMESPACE' delete pod '$pod' --wait=false >/dev/null 2>&1; exit 130" INT TERM
  for ((i = 0; i < NODE_TIMEOUT; i += 2)); do
    phase=$(kubectl -n "$DEBUG_NAMESPACE" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
    reason=$(kubectl -n "$DEBUG_NAMESPACE" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
    [[ "$reason" == *ImagePull* || "$reason" == InvalidImageName ]] && break
    sleep 2
  done
  if [[ "$phase" == Succeeded || "$phase" == Failed ]]; then
    kubectl -n "$DEBUG_NAMESPACE" logs "$pod" 2>&1
    rc=$(kubectl -n "$DEBUG_NAMESPACE" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')
  else
    echo "debug pod $DEBUG_NAMESPACE/$pod did not finish (phase ${phase:-?}${reason:+, $reason}; image $DEBUG_IMAGE)"
    rc=1
  fi
  kubectl -n "$DEBUG_NAMESPACE" delete pod "$pod" --wait=false >/dev/null 2>&1
  trap - INT TERM
  return "${rc:-1}"
}

# load_target_nodes [comma-separated names]: sets TARGETS to one node name per line. Without names, picks the nodes
# kata-deploy schedules onto by default: every node without a NoSchedule/NoExecute taint (normally the workers).
load_target_nodes() {
  local want=${1:-} all
  all=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.taints[*].effect}{"\n"}{end}') \
    || die "cannot list nodes (check KUBECONFIG and cluster access)"
  if [[ -n "$want" ]]; then
    TARGETS=$(awk -v want=",$want," 'index(want, ","$1",") {print $1}' <<<"$all")
    local n
    for n in ${want//,/ }; do grep -qx "$n" <<<"$TARGETS" || die "node $n not found"; done
    awk -v want=",$want," 'index(want, ","$1",") && /NoSchedule|NoExecute/ {print $1}' <<<"$all" | while read -r n; do
      echo "WARNING: $n is tainted; kata-deploy and test pods only run there with matching tolerations (for kata-deploy: helm --set tolerations...)" >&2
    done
  else
    TARGETS=$(awk '$0 !~ /NoSchedule|NoExecute/ {print $1}' <<<"$all")
  fi
  [[ -n "$TARGETS" ]] || die "no target nodes (pass --nodes)"
}

has_shim() { [[ " $SHIMS " == *" $1 "* ]]; }
