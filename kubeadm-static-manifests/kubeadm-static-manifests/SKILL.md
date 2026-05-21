---
name: kubeadm-static-manifests
description: Modify kubeadm Kubernetes control plane static pod manifests safely. Use when an agent needs to add, remove, or change flags/arguments on kube-apiserver, kube-controller-manager, kube-scheduler, or etcd, or when adding volume mounts to these components (e.g., for audit policies, encryption config, webhook config). Triggers on tasks involving kubeadm cluster configuration, control plane hardening, enabling feature gates, adding admission controllers, or any modification to files in /etc/kubernetes/manifests/.
---

# Kubeadm Static Pod Manifests

## Critical Rule: Never Edit In-Place

The kubelet watches `/etc/kubernetes/manifests/` via inotify. Every filesystem event (write, create, rename) triggers a manifest re-read. Partial writes or temp files in that directory cause the kubelet to read corrupt/empty manifests, cache stale specs, and refuse to pick up subsequent changes.

**Always use the copy-out/edit/copy-back pattern.**

## Workflow: Modifying a Static Pod

### 1. Copy the manifest out

```bash
cp /etc/kubernetes/manifests/<component>.yaml /tmp/<component>.yaml
```

Components: `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `etcd`.

### 2. Edit in /tmp

Make all changes to `/tmp/<component>.yaml`. Use `sed`, a script, or any editing tool.

**Adding a flag** (match an existing nearby flag, not the command name):
```bash
sed -i '/--service-account-key-file/a\    - --profiling=false' /tmp/kube-apiserver.yaml
```

**Modifying an existing flag:**
```bash
sed -i 's/--existing-flag=old/--existing-flag=new/' /tmp/kube-apiserver.yaml
```

**Removing a flag:**
```bash
sed -i '/--unwanted-flag/d' /tmp/kube-apiserver.yaml
```

Always match against an existing flag in the `command:` list to ensure correct indentation and placement. Never match the command name (e.g., `- kube-apiserver`) as the anchor.

### 3. Copy the finished file back

```bash
cp /tmp/<component>.yaml /etc/kubernetes/manifests/<component>.yaml
```

This is a single atomic write from the kubelet's perspective.

### 4. Verify the restart

The kubelet detects the change and restarts the pod within 5–30 seconds. Poll for the expected change:

```bash
for i in $(seq 1 12); do
  sleep 5
  if ps -ef | grep '[k]ube-apiserver' | grep -q 'new-flag'; then
    echo "Restart confirmed"
    break
  fi
  [ "$i" -eq 12 ] && echo "ERROR: restart not detected after 60s"
done
```

Also verify the pod is running:
```bash
crictl pods --name kube-apiserver -s ready
```

## Adding Volume Mounts

When a flag references a file on disk (audit policy, encryption config, webhook kubeconfig, etc.), the file must be mounted into the static pod. This requires adding both a `volume` and a `volumeMount` to the manifest.

### Warning: sed is dangerous for volume mounts

Field names like `name:` appear in both `spec.volumes` and `spec.containers[0].volumeMounts`. A naive sed match (e.g., matching on `name: usr-share-ca-certificates`) will hit both sections, corrupting the manifest. For volume mount changes, **do not use sed with field-name anchors**. Instead:

- Use the `status: {}` line at the end of the manifest as an anchor for inserting volumes (insert before it)
- Use line-number-based insertion with `sed '<N>a\...'` after inspecting the file with `grep -n`
- Or use `awk` with section-aware logic

### Procedure

1. Place the config file on the host filesystem (e.g., `/etc/kubernetes/audit/policy.yaml`)
2. Copy the manifest out per the workflow above
3. Add the volume under `spec.volumes`. Use `status: {}` at the end of the manifest as an anchor:

```bash
# Insert volume entry before the status: {} line
sed -i '/^status: {}/i\  - name: audit-policy\n    hostPath:\n      path: /etc/kubernetes/audit\n      type: DirectoryOrCreate' /tmp/kube-apiserver.yaml
```

4. Add the volumeMount under `spec.containers[0].volumeMounts`. Find the exact line range first:

```bash
# Find the last volumeMount entry's line number and insert after it
LAST_VMOUNT=$(grep -n 'mountPath:' /tmp/kube-apiserver.yaml | tail -1 | cut -d: -f1)
sed -i "${LAST_VMOUNT}a\\    - name: audit-policy\n      mountPath: /etc/kubernetes/audit\n      readOnly: true" /tmp/kube-apiserver.yaml
```

5. Add the flag referencing the in-container path (using the standard flag insertion method):

```bash
sed -i '/--service-account-key-file/a\    - --audit-policy-file=/etc/kubernetes/audit/policy.yaml' /tmp/kube-apiserver.yaml
```

6. Copy back and verify.

**Use `readOnly: true`** on mounts unless the component needs to write (e.g., audit log output directory).

For common volume mount examples, see [references/volume-mount-examples.md](references/volume-mount-examples.md).

## Troubleshooting

If the pod does not restart after 60 seconds:

1. Check kubelet logs: `journalctl -u kubelet -n 50 --no-pager`
2. Validate YAML syntax (python3 may not be installed on minimal kubeadm nodes — if not, use `kubectl --kubeconfig=/etc/kubernetes/admin.conf apply --dry-run=client -f /etc/kubernetes/manifests/<component>.yaml` or visually inspect the file)
3. Check for duplicate flags — the API server rejects duplicate arguments
4. Verify file permissions on any mounted config files (must be readable by root)

If the pod enters a crash loop:

1. Check container logs: `crictl logs $(crictl ps -a --name kube-apiserver -q | head -1)`
2. Revert by copying the backup: `cp /tmp/<component>.yaml.bak /etc/kubernetes/manifests/<component>.yaml`

**Always keep a backup** before starting: `cp /tmp/<component>.yaml /tmp/<component>.yaml.bak` right after the initial copy-out. For multi-step modifications, take a fresh backup each time you copy the manifest out — the previous backup will reflect an earlier state.
