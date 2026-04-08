---
name: container-vuln-testing
description: Test container runtime vulnerabilities (runc, containerd, CRI-O) against the full container stack — from direct runtime invocation through Docker, containerd, Kubernetes API, and node-level access. Use when validating whether a container runtime vulnerability is exploitable through each layer of the stack, or when you need to determine which layers block an exploit and which don't. Triggers on tasks involving container escape testing, runc vulnerability validation, container runtime security research, testing security boundaries between Docker/containerd/Kubernetes and runc, or determining exploitability of OCI runtime bugs across different deployment contexts. Requires labctl for ephemeral test environments.
---

# Container Vulnerability Testing

Systematically test container runtime vulnerabilities (runc, containerd, CRI-O) against each layer of the container stack to determine real-world exploitability. Uses `labctl` playgrounds for ephemeral, isolated test environments.

## Why Layer-by-Layer Testing Matters

Container runtime vulnerabilities don't exist in isolation. A bug in runc may be:
- **Exploitable** via direct runc invocation but **blocked** by Docker's validation
- **Blocked** by Kubernetes API admission but **exploitable** from a privileged pod on the node
- **Accidentally mitigated** by containerd's user resolution logic without anyone realizing it

Each layer in the stack may independently validate, transform, or block inputs before they reach runc. Testing only one layer gives an incomplete picture. The goal is to map exactly which paths are exploitable and which aren't.

## Prerequisites

- `labctl` installed, on PATH, and authenticated (`labctl auth login`)
- Use the `labctl-playground` skill for playground lifecycle management
- Authorization to perform security testing

## Testing Strategy

Test from the **most direct** (closest to runc) to the **most abstracted** (Kubernetes API):

```
Layer 1: runc exec directly          (the runtime itself)
Layer 2: containerd ctr              (container daemon CLI)
Layer 3: Docker CLI / Docker daemon  (full Docker stack)
Layer 4: Kubernetes API              (orchestrator layer)
Layer 5: Kubernetes node-level       (escape back to runc from inside K8s)
```

If a vulnerability is blocked at Layer 4, you still need to check Layer 5 — an attacker with node access can bypass the Kubernetes API entirely.

## Phase 1: Docker / containerd / Direct runc

Use a `docker` playground. This gives you Docker, containerd, `ctr`, and runc all on a single machine.

### Start the environment

```bash
PLAYGROUND_ID=$(labctl playground start docker --quiet)
```

### Identify versions

```bash
labctl ssh "$PLAYGROUND_ID" --user root -- bash -c '
    echo "Docker:     $(docker --version)"
    echo "containerd: $(containerd --version)"
    echo "runc:       $(runc --version | head -1)"
    echo "Arch:       $(uname -m) ($(getconf LONG_BIT)-bit)"
'
```

### Layer 1: Direct runc exec

runc manages container state under a "root" directory. When Docker is the container manager, this is typically `/run/docker/runtime-runc/moby`.

```bash
# Write a test script and copy it to the playground
cat > /tmp/test_runc.sh << 'SCRIPT'
#!/bin/bash
# Start a container via Docker (easiest way to get a running runc container)
docker run -d --name test-target busybox sleep 3600
FULL_ID=$(docker inspect test-target --format '{{.Id}}')
RUNC_ROOT="/run/docker/runtime-runc/moby"

# Verify runc can see it
runc --root "$RUNC_ROOT" list

# Run your exploit test against the container directly
# Example: runc --root "$RUNC_ROOT" exec --user <value> "$FULL_ID" id
# Replace with your specific vulnerability test

docker rm -f test-target
SCRIPT

labctl cp /tmp/test_runc.sh "$PLAYGROUND_ID":/home/laborant/test_runc.sh
labctl ssh "$PLAYGROUND_ID" -- chmod +x /home/laborant/test_runc.sh
labctl ssh "$PLAYGROUND_ID" --user root -- /home/laborant/test_runc.sh
```

**Key points for direct runc testing:**
- Must run as **root** — runc state directories have restrictive permissions
- Use `labctl ssh --user root` to run commands as root
- The container ID for runc is the full Docker container ID (64 hex chars), not the short form
- runc exec requires the container to be in "running" state

### Layer 2: containerd (ctr)

containerd has its own CLI (`ctr`) that bypasses Docker but still goes through containerd's API before reaching runc.

```bash
labctl ssh "$PLAYGROUND_ID" --user root -- bash -c '
    # Pull an image into containerd default namespace
    ctr images pull docker.io/library/busybox:latest

    # Run a container directly via containerd
    ctr run -d docker.io/library/busybox:latest ctr-test /bin/sleep 3600

    # Test your exploit via ctr
    # Example: ctr task exec --exec-id test1 --user <value> ctr-test id
    # Replace with your specific vulnerability test

    # Cleanup
    ctr task kill ctr-test --signal SIGKILL
    sleep 1
    ctr task delete ctr-test
    ctr containers delete ctr-test
'
```

**Key points for ctr testing:**
- `ctr` has a `--user` flag for exec but processes it differently than runc's `--user`
- containerd may do user resolution (mounting rootfs, reading `/etc/passwd`) before invoking runc
- containerd uses `exec-id` to track exec sessions — each must be unique per container
- Docker containers live in the `moby` namespace: `ctr -n moby task list`

### Layer 3: Docker CLI

```bash
labctl ssh "$PLAYGROUND_ID" --user root -- bash -c '
    docker run -d --name docker-test busybox sleep 3600

    # Test via Docker CLI
    # Example: docker exec --user <value> docker-test id
    # Replace with your specific vulnerability test

    docker rm -f docker-test
'
```

**Key points for Docker testing:**
- Docker daemon adds validation on various fields (e.g., UID range 0-2147483647)
- Docker validation errors come from the daemon, not runc
- Errors at this layer don't mean runc is safe — only that Docker blocks it

### Cleanup Phase 1

```bash
labctl playground destroy "$PLAYGROUND_ID"
```

## Phase 2: Kubernetes

Use a `k3s` playground. This gives a multi-node K3s cluster with containerd and runc.

### Start the environment

```bash
PLAYGROUND_ID=$(labctl playground start k3s --quiet)
```

K3s playgrounds have multiple machines. Use `dev-machine` for kubectl:

```bash
labctl ssh "$PLAYGROUND_ID" --machine dev-machine -- kubectl get nodes -o wide
```

### Layer 4: Kubernetes API

Test whether the Kubernetes API server accepts or rejects the exploit values in pod specs.

```bash
labctl ssh "$PLAYGROUND_ID" --machine dev-machine -- bash -c '
    # Test pod spec with exploit values
    # Example: runAsUser, capabilities, volumes, securityContext fields
    cat <<EOF | kubectl apply -f - 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: exploit-test
spec:
  securityContext:
    runAsUser: <EXPLOIT_VALUE>
  containers:
  - name: test
    image: busybox
    command: ["sleep", "3600"]
  restartPolicy: Never
EOF

    # Check if the API accepted or rejected it
    kubectl get pod exploit-test -o wide 2>&1
    kubectl delete pod exploit-test --force --grace-period=0 2>/dev/null
'
```

**Key points for Kubernetes API testing:**
- The API server validates many security-relevant fields (runAsUser, capabilities, etc.)
- Pod Security Standards (PSS) and admission webhooks add more validation
- Even if the API blocks something, the underlying runc may still be vulnerable via node access
- Use `busybox` image — alpine images in K3s may lack common utilities like `id`

### Layer 5: Node-level runc from inside Kubernetes

This is the critical test: can an attacker who has gained node access in a Kubernetes cluster exploit the vulnerability directly?

**Step 1: Create a target pod to test against**

```bash
labctl ssh "$PLAYGROUND_ID" --machine dev-machine -- bash -c '
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: target-pod
spec:
  containers:
  - name: target
    image: busybox
    command: ["sleep", "3600"]
  restartPolicy: Never
EOF
    kubectl wait --for=condition=Ready pod/target-pod --timeout=60s
'
```

**Step 2: Create a privileged pod on the same node to access runc**

```bash
labctl ssh "$PLAYGROUND_ID" --machine dev-machine -- bash -c '
    TARGET_NODE=$(kubectl get pod target-pod -o jsonpath="{.spec.nodeName}")

    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: runc-tester
spec:
  nodeName: $TARGET_NODE
  hostPID: true
  containers:
  - name: tester
    image: busybox
    command: ["sleep", "3600"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: host
      mountPath: /host
  volumes:
  - name: host
    hostPath:
      path: /
  restartPolicy: Never
EOF
    kubectl wait --for=condition=Ready pod/runc-tester --timeout=60s
'
```

**Step 3: Access runc from inside the node namespace**

```bash
labctl ssh "$PLAYGROUND_ID" --machine dev-machine -- bash -c '
    kubectl exec runc-tester -- nsenter -t 1 -m -u -i -n -p -- sh -c '\''
        # Find K3s bundled runc
        RUNC=$(find /var/lib/rancher/k3s/data -name runc -type f 2>/dev/null | head -1)
        RUNC_ROOT="/run/containerd/runc/k8s.io"

        echo "runc: $($RUNC --version | head -1)"

        # Find a container with the test binary available
        for CID in $($RUNC --root $RUNC_ROOT list -q 2>/dev/null); do
            if $RUNC --root $RUNC_ROOT exec $CID /bin/id >/dev/null 2>&1; then
                echo "Target container: $CID"

                # Run your exploit test
                # Example: $RUNC --root $RUNC_ROOT exec --user <value> $CID /bin/id
                break
            fi
        done
    '\''
'
```

**Key points for K3s node-level testing:**
- K3s bundles runc at `/var/lib/rancher/k3s/data/<hash>/bin/runc` — it's NOT in the standard `$PATH`
- The runc state directory for K3s containers is `/run/containerd/runc/k8s.io`
- Use `nsenter -t 1 -m -u -i -n -p` to enter the node's full namespace from a privileged pod
- A privileged pod with `hostPID: true` is required for nsenter to work
- Not all container images have the tools you need — use `busybox` which includes `id`, `cat`, `ls`, etc.
- Alpine images pulled by K3s may be minimal and lack `/bin/id`

### Cleanup Phase 2

```bash
labctl ssh "$PLAYGROUND_ID" --machine dev-machine -- bash -c '
    kubectl delete pod target-pod runc-tester --force --grace-period=0 2>/dev/null
'
labctl playground destroy "$PLAYGROUND_ID"
```

## Practical Tips

### Script management

Write test scripts locally, copy them to the playground, and run them. This is more reliable than passing complex inline bash through `labctl ssh`:

```bash
labctl cp ./my_test.sh "$PLAYGROUND_ID":/home/laborant/my_test.sh
labctl ssh "$PLAYGROUND_ID" -- chmod +x /home/laborant/my_test.sh
labctl ssh "$PLAYGROUND_ID" --user root -- /home/laborant/my_test.sh
```

The default user is `laborant` (home: `/home/laborant`). Use `--user root` for root access.

### Handling errors

- Test scripts should use `set +e` (or no `set -e`) so they continue past individual test failures
- Capture both stdout and stderr: `result=$(command 2>&1)`
- Always record exit codes: `echo "Exit: $?"`
- Wrap each test in a function for clean output

### Common pitfalls

| Problem | Solution |
|---------|----------|
| `runc list` permission denied | Use `--user root` with labctl ssh |
| Container ID not found by runc | Use full 64-char Docker ID, not short form |
| `/bin/id` not found in container | Use `busybox` image instead of `alpine` |
| K3s runc not in PATH | Find it: `find /var/lib/rancher/k3s/data -name runc -type f` |
| ctr exec-id conflict | Use unique exec-id strings for each exec call |
| `bash -c` not passing through labctl ssh | Write a script file, copy it, run it |
| Alpine missing tools in K3s | K3s pulls minimal images; use `busybox:latest` |

### Recording results

For each vulnerability test, record a table like this:

| Attack Path | Exploitable? | Validated? | Notes |
|---|---|---|---|
| `runc` direct (version X.Y.Z) | YES/NO | Confirmed/Not tested | Details |
| `docker exec` | YES/NO | Confirmed/Not tested | Details |
| `ctr task exec` | YES/NO | Confirmed/Not tested | Details |
| Kubernetes API (pod spec) | YES/NO | Confirmed/Not tested | Details |
| K8s node-level runc | YES/NO | Confirmed/Not tested | Details |

This makes it clear which layers provide mitigation and which don't.

## Reference: Container Stack Architecture

```
┌─────────────────────────────────────┐
│  Kubernetes API Server              │ ← Layer 4: API validation
│  (admission, PSS, webhooks)         │   (runAsUser range, capabilities, etc.)
├─────────────────────────────────────┤
│  kubelet                            │
├─────────────────────────────────────┤
│  CRI (containerd / CRI-O)          │ ← Layer 2/3: Runtime validation
│  (user resolution, image pull,      │   (containerd user lookup, Docker
│   sandbox creation)                 │    daemon UID range check, etc.)
├─────────────────────────────────────┤
│  OCI Runtime (runc)                 │ ← Layer 1: The runtime itself
│  (namespace setup, cgroup config,   │   (often the weakest validation)
│   exec, signal, delete)             │
├─────────────────────────────────────┤
│  Linux Kernel                       │ ← Layer 0: Kernel enforcement
│  (namespaces, cgroups, seccomp,     │   (uid_map, capabilities, etc.)
│   LSMs, UID/GID enforcement)        │
└─────────────────────────────────────┘
```

A vulnerability in runc (Layer 1) may be blocked by any layer above it, or by the kernel below it. The kernel is the ultimate enforcer — even if runc passes a bad value, the kernel may reject it (e.g., unmapped UIDs in user namespaces). Full testing covers all layers.

## Reference: runc State Directories

| Container Manager | runc Root Directory |
|---|---|
| Docker | `/run/docker/runtime-runc/moby` |
| K3s (containerd CRI) | `/run/containerd/runc/k8s.io` |
| containerd (default ns) | `/run/containerd/runc/default` |
| CRI-O | `/run/runc` |
| Podman | `/run/user/<uid>/runc` (rootless) or `/run/runc` (rootful) |

## Reference: runc Binary Locations

| Distribution | Path |
|---|---|
| Docker (apt/yum) | `/usr/bin/runc` or `/usr/sbin/runc` |
| K3s (bundled) | `/var/lib/rancher/k3s/data/<hash>/bin/runc` |
| containerd (standalone) | `/usr/bin/runc` or `/usr/local/bin/runc` |
| RKE2 (bundled) | `/var/lib/rancher/rke2/data/<hash>/bin/runc` |
