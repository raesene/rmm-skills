#!/bin/bash
# verify-cluster.sh <kubeconfig>: independent check of the sandboxed runtimes on a test cluster.
# For every RuntimeClass: start a busybox pod, record pod kernel vs node kernel, first dmesg line, and the sandbox
# processes on the node (qemu/firecracker/runsc + --platform). Also checks a plain runc pod still works.
export KUBECONFIG=$1
ns=kgi-verify
kubectl create ns $ns >/dev/null 2>&1
echo "== runtimeclasses"; kubectl get runtimeclass -o custom-columns=NAME:.metadata.name,HANDLER:.handler --no-headers
echo "== leftover pods outside kube-system/calico"
kubectl get pods -A --no-headers | grep -vE '^(kube-system|calico-system|tigera-operator|calico-apiserver|kgi-verify) ' || echo none
probe() {  # probe <pod> <runtimeclass|"">
  local pod=$1 rc=$2 ov='{"spec":{}}'
  [[ -n $rc ]] && ov="{\"spec\":{\"runtimeClassName\":\"$rc\"}}"
  kubectl -n $ns run $pod --image=busybox:1.36 --restart=Never --overrides="$ov" -- sleep 600 >/dev/null 2>&1
  if ! kubectl -n $ns wait --for=condition=Ready pod/$pod --timeout=240s >/dev/null 2>&1; then
    echo "RESULT rc=${rc:-runc} ready=no $(kubectl -n $ns get events --field-selector involvedObject.name=$pod -o jsonpath='{.items[-1:].message}' | head -c 200)"; return
  fi
  local node uid pk nk dm procs
  node=$(kubectl -n $ns get pod $pod -o jsonpath='{.spec.nodeName}')
  uid=$(kubectl -n $ns get pod $pod -o jsonpath='{.metadata.uid}')
  pk=$(kubectl -n $ns exec $pod -- uname -r 2>&1)
  nk=$(kubectl get node $node -o jsonpath='{.status.nodeInfo.kernelVersion}')
  dm=$(kubectl -n $ns exec $pod -- dmesg 2>&1 | head -1 | head -c 80)
  echo "RESULT rc=${rc:-runc} ready=yes node=$node pod_kernel=$pk node_kernel=$nk dmesg='$dm' uid=$uid"
}
probe p-runc ""
for rc in $(kubectl get runtimeclass -o jsonpath='{.items[*].metadata.name}'); do probe "p-$rc" "$rc"; done
# node-side processes: one debug pod per node, list sandbox VMMs / runsc with platform
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  out=$(kubectl debug node/$node -n kube-system --profile=sysadmin --image=busybox:1.36 -- chroot /host sh -c \
    "pgrep -a 'qemu|firecracker|cloud-hyp' | cut -c1-120; ps -eo args | grep '^runsc-sandbox' | grep -o -- '--platform=[a-z]*' | sort | uniq -c" 2>&1)
  pod=$(grep -o 'node-debugger-[^ ]*' <<<"$out" | head -1)
  for i in $(seq 1 60); do ph=$(kubectl -n kube-system get pod $pod -o jsonpath='{.status.phase}'); [[ $ph == Succeeded || $ph == Failed ]] && break; sleep 2; done
  echo "== node $node processes"; kubectl -n kube-system logs $pod; kubectl -n kube-system delete pod $pod --wait=false >/dev/null
done
kubectl delete ns $ns --wait=false >/dev/null
