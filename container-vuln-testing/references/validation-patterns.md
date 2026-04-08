# Validation Patterns — What We've Learned

Patterns observed from validating runc vulnerabilities across the container stack.

## Pattern: Each Layer Validates Independently

Docker, containerd, and Kubernetes each have their own input validation. None of them rely on runc to validate — they all do it themselves (or not). This means:

- A bug in runc's validation may be masked by Docker's validation in Docker-only environments
- The same bug is fully exploitable in environments that call runc directly
- containerd may accidentally block something through a side effect (e.g., user resolution) rather than an intentional check
- Kubernetes validates at the API server, but node-level access bypasses this entirely

## Pattern: Accidental vs Deliberate Mitigations

Not all protections are intentional. Examples observed:

| Component | Mitigation | Deliberate? |
|---|---|---|
| Docker daemon | UID range 0-2147483647 | Yes — explicit error message |
| containerd ctr | UID > int32 max fails user lookup | **No** — side effect of user resolution |
| Kubernetes API | runAsUser 0-2147483647 | Yes — explicit validation message |
| Go JSON decoder | Rejects uint32 overflow in process.json | **No** — type system enforcement |

Accidental mitigations can disappear with refactoring. They should not be relied upon as security boundaries.

## Pattern: Multiple Input Paths to the Same Code

runc's `exec.go` has two input paths for UID:

1. **CLI `--user` flag** → `strconv.Atoi` (int) → `uint32()` cast → VULNERABLE
2. **`--process` JSON file** → Go JSON decoder → uint32 struct field → NOT VULNERABLE

The same underlying code has different exploitability depending on which input path is used. Always test all input paths, not just the most obvious one.

## Pattern: Privileged Pods as Node-Level Access

In Kubernetes, a pod with `hostPID: true` + `privileged: true` + a hostPath volume can `nsenter` into the node's namespaces and invoke runc directly. This is a well-known pattern that:

- Bypasses all Kubernetes API server validation
- Gives full access to the container runtime on the node
- Is available to anyone with permissions to create privileged pods
- Is the standard way to test node-level vulnerabilities from within a cluster

## Pattern: Image Differences Matter

The same image name (`alpine`) may contain different binaries depending on how it was pulled:

- Docker Hub `alpine:latest` pulled by Docker → has `/bin/id`
- Same image pulled by K3s → may lack `/bin/id` (minimal layer differences)
- `busybox:latest` is the most reliable for testing — guaranteed to have standard utils

Always verify that test binaries exist in the container before concluding a test failed.

## Pattern: runc Versions Across Distributions

runc versions vary significantly across distributions. A vulnerability might be fixed in one version but present in another:

| Source | Typical runc version (as of 2026) |
|---|---|
| Docker CE (apt) | runc 1.3.x or 1.4.x |
| K3s (bundled) | runc 1.4.x |
| RKE2 (bundled) | runc 1.4.x |
| Ubuntu 24.04 (distro) | runc 1.1.x (older!) |
| RHEL 9 (distro) | runc 1.1.x (older!) |

Always check `runc --version` on the target before testing.
