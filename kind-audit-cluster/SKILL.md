---
name: kind-audit-cluster
description: Create Kind (Kubernetes in Docker) clusters with Kubernetes API server auditing enabled. Use when setting up local Kubernetes clusters that need audit logging, testing audit policies, or debugging Kubernetes API interactions. Focuses on the critical two-level volume mount configuration required to get auditing working correctly.
compatibility: Requires kind, kubectl, and Docker installed on the host system.
metadata:
  author: rorym
  version: "1.0"
---

# Kind Cluster with Kubernetes Auditing

This skill enables LLM agents to create Kind clusters with Kubernetes API server auditing enabled.

## Key Concept: Two-Level Volume Mounting

Enabling Kubernetes auditing in Kind requires careful configuration of volume mounts at two distinct levels. This is the most common source of errors.

Kind runs Kubernetes nodes as Docker containers. The kube-apiserver runs as a static pod inside that container. This creates a two-level mount requirement:

```
Host filesystem → Kind container → kube-apiserver pod
     (extraMounts)      (extraVolumes in kubeadmConfigPatches)
```

**Both levels must be configured correctly** or auditing will fail silently.

## Required Files

### 1. Audit Policy File (audit-policy.yaml)

Create a Kubernetes audit policy that defines what events to log:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # Log pod changes at RequestResponse level (includes request and response bodies)
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods"]

  # Log configmap and secret changes at Metadata level (no bodies, for security)
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]

  # Log all other resources at Metadata level
  - level: Metadata
    omitStages:
      - RequestReceived
```

Audit levels from least to most verbose: `None`, `Metadata`, `Request`, `RequestResponse`

### 2. Kind Cluster Configuration (kind-config.yaml)

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraMounts:
      # LEVEL 1: Mount audit policy from host into Kind container
      - hostPath: /absolute/path/to/audit-policy.yaml
        containerPath: /etc/kubernetes/audit-policy.yaml
        readOnly: true
      # LEVEL 1: Mount directory for audit logs from host into Kind container
      - hostPath: /absolute/path/to/audit-logs
        containerPath: /var/log/kubernetes/audit
    kubeadmConfigPatches:
      - |
        kind: ClusterConfiguration
        apiServer:
          extraArgs:
            audit-policy-file: /etc/kubernetes/audit-policy.yaml
            audit-log-path: /var/log/kubernetes/audit/audit.log
            audit-log-maxage: "30"
            audit-log-maxbackup: "3"
            audit-log-maxsize: "100"
          extraVolumes:
            # LEVEL 2: Mount audit policy from Kind container into kube-apiserver pod
            - name: audit-policy
              hostPath: /etc/kubernetes/audit-policy.yaml
              mountPath: /etc/kubernetes/audit-policy.yaml
              readOnly: true
            # LEVEL 2: Mount audit logs directory from Kind container into kube-apiserver pod
            - name: audit-logs
              hostPath: /var/log/kubernetes/audit
              mountPath: /var/log/kubernetes/audit
```

## Volume Mount Details

### Level 1: extraMounts (Host → Kind Container)

These mounts use Docker's volume mounting to get files from the host into the Kind container:

| Field | Description |
|-------|-------------|
| `hostPath` | Absolute path on the host machine (your workstation) |
| `containerPath` | Path inside the Kind Docker container |
| `readOnly` | Set to `true` for policy file, omit for logs directory |

### Level 2: extraVolumes (Kind Container → kube-apiserver Pod)

These mounts use Kubernetes hostPath volumes to get files from the Kind container's filesystem into the kube-apiserver pod:

| Field | Description |
|-------|-------------|
| `name` | Unique name for the volume |
| `hostPath` | Path inside the Kind container (must match Level 1 containerPath) |
| `mountPath` | Path inside the kube-apiserver container |
| `readOnly` | Set to `true` for policy file |

## Critical Requirements

1. **Use absolute paths** for all hostPath values in extraMounts
2. **Paths must align**: The `containerPath` in extraMounts must match the `hostPath` in extraVolumes
3. **Create the audit-logs directory** before running `kind create cluster`
4. **The audit-logs directory must be writable** by the container (do not set readOnly for logs)
5. **All values in extraArgs must be strings** (wrapped in quotes in YAML)

## Setup Commands

```bash
# 1. Create the audit logs directory
mkdir -p /path/to/audit-logs

# 2. Create the cluster
kind create cluster --name my-audit-cluster --config kind-config.yaml

# 3. Verify auditing is working
kubectl get pods -n kube-system  # This should generate audit events
cat /path/to/audit-logs/audit.log | head -20
```

## Troubleshooting

### No audit.log file created
- Check that the audit-logs directory exists and is writable
- Verify both levels of mounts are configured
- Check kube-apiserver logs: `kubectl logs -n kube-system kube-apiserver-<node-name>`

### kube-apiserver fails to start
- Check for typos in paths
- Ensure the audit-policy.yaml file exists at the specified hostPath
- Verify the audit policy YAML is valid

### Empty audit.log
- The audit policy may be filtering out all events
- Add a catch-all rule with `level: Metadata`

## Cleanup

```bash
kind delete cluster --name my-audit-cluster
```

## Example: Generating the Configuration Programmatically

When generating configurations for users, replace placeholder paths with actual paths:

```bash
# Get absolute path to current directory
AUDIT_DIR="$(pwd)"

# Generate kind-config.yaml with correct paths
cat > kind-config.yaml << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: ${AUDIT_DIR}/audit-policy.yaml
        containerPath: /etc/kubernetes/audit-policy.yaml
        readOnly: true
      - hostPath: ${AUDIT_DIR}/audit-logs
        containerPath: /var/log/kubernetes/audit
    kubeadmConfigPatches:
      - |
        kind: ClusterConfiguration
        apiServer:
          extraArgs:
            audit-policy-file: /etc/kubernetes/audit-policy.yaml
            audit-log-path: /var/log/kubernetes/audit/audit.log
            audit-log-maxage: "30"
            audit-log-maxbackup: "3"
            audit-log-maxsize: "100"
          extraVolumes:
            - name: audit-policy
              hostPath: /etc/kubernetes/audit-policy.yaml
              mountPath: /etc/kubernetes/audit-policy.yaml
              readOnly: true
            - name: audit-logs
              hostPath: /var/log/kubernetes/audit
              mountPath: /var/log/kubernetes/audit
EOF
```

## Summary

The key to successfully enabling Kind auditing is understanding that mounts must be configured at two levels:

1. **extraMounts**: Gets files from your host into the Kind Docker container
2. **extraVolumes**: Gets files from the Kind container into the kube-apiserver pod

The `containerPath` from Level 1 must equal the `hostPath` from Level 2 for the same resource. This creates a continuous path from your host filesystem into the kube-apiserver.
