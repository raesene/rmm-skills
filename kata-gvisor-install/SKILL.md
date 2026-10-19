---
name: kata-gvisor-install
description: >
  Add sandboxed container runtimes — Kata Containers (QEMU, Firecracker) and/or gVisor (runsc, systrap or KVM platform) —
  to an existing Kubernetes cluster that runs containerd, using bundled scripts that need only kubectl/helm API access
  (node changes go through short-lived `kubectl debug node` pods, no SSH). Covers the readiness check, kata-deploy with
  chosen shims, the devmapper thin pool Firecracker needs, runsc install plus containerd handlers, RuntimeClasses, and
  smoke tests that prove pods really run in a VM / gVisor sandbox. Use this whenever someone wants to install, add,
  enable, set up, check readiness for, or troubleshoot Kata, kata-deploy, Firecracker-backed pods, gVisor, runsc,
  sandboxed or VM-isolated pods, or `runtimeClassName` sandboxes on a kubeadm-style, self-managed or lab cluster —
  even if they just say "make this cluster able to run untrusted workloads in a sandbox".
---

# Install Kata Containers and gVisor on a Kubernetes cluster

The bundled scripts in `scripts/` do the work. They target any kubeadm-style cluster whose nodes run containerd under
systemd, and use only the current `KUBECONFIG` context (cluster-admin). Anything that has to happen on a node runs in a
`kubectl debug node/<n> --profile=sysadmin` pod that `chroot`s into the host and is deleted afterwards — so SSH to the
nodes is not needed.

| Script | Purpose |
|---|---|
| `scripts/check-prereqs.sh` | Read-only readiness report (PASS/WARN/FAIL/INFO per check, per node). Exit 1 on any FAIL. |
| `scripts/install-kata.sh` | kata-deploy Helm chart with chosen shims; devmapper thin pool for `fc`; smoke test per RuntimeClass. |
| `scripts/install-gvisor.sh` | runsc from the release tarball, containerd handlers, node labels, RuntimeClasses, smoke test. |
| `scripts/lib.sh` | Shared helpers (`node_bash`, target-node selection). Sourced, not run. |

Run them by absolute path from this skill directory (they find `lib.sh` via `dirname $0`). Every script has `-h`.

## Workflow

These scripts change real nodes: they write containerd config, restart containerd on every target node, install
binaries in `/usr/local/bin`, and for Firecracker create an LVM thin pool. So the shape is always
**check → dry-run → confirm with the user → install → verify**.

### 1. Make sure you are pointed at the right cluster

Run `kubectl config current-context` and `kubectl get nodes -o wide` and say which cluster you're about to touch.
Getting the context wrong is the most expensive mistake available here, so don't skip it. If the user's setup needs a
tunnel or a specific kubeconfig (a project `config.env`, `KUBECONFIG=...`), set that up first.

Also check the cluster type. These scripts are for self-managed clusters (kubeadm, k3s-with-containerd-and-systemd,
lab VMs). On managed services prefer the provider's own feature (GKE Sandbox for gVisor, etc.) and tell the user why;
on kind/Docker-based nodes, systemd/KVM assumptions often don't hold — run the check and let it decide.

### 2. Decide what to install

Map the request onto options. If the user didn't say, use the defaults and mention them.

**Kata** (`install-kata.sh`, needs helm ≥ 3.8 and `/dev/kvm` on the nodes, x86_64 only):
- `--shims` — space-separated, first = default shim. Default `"qemu-runtime-rs qemu"`. Each shim becomes a RuntimeClass
  `kata-<shim>`. `qemu-runtime-rs` is the Kata 4.x Rust runtime (preferred); `qemu` the legacy Go one; `fc` is
  Firecracker and additionally needs the devmapper snapshotter (kernel dm-thin, lvm2, thin-provisioning-tools) — the
  script builds a thin pool from a sparse loop file (`--pool-gb`, default 20; keep it below the free space in
  `/var/lib`, which the check reports) or an empty disk (`--pool-device`). `--install-fc-tools` installs lvm2 and
  thin-provisioning-tools on the nodes with their package manager; minimal node images often lack them.
  Other shims (e.g. `clh`, `qemu-nvidia-gpu`) exist; see `helm show values oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy --version <v>`.
- `--version` — kata-deploy chart version, default `4.2.0`.
- `--agent-timeout` — seconds the runtime-rs shims wait for the guest agent (default 45). Kata's own default is 3 s,
  which nested or busy nodes miss ("vsock ... within 10s" and the pod never starts), so leave this alone unless asked.
- `--values file.yaml` — extra kata-deploy Helm values, applied last. Every run of the script replaces the release's
  values with its own, so any custom chart setting (a shim `dropIn`, tolerations, ...) must go in a values file passed
  here, never in a hand-run `helm upgrade` — the next run of the script would silently drop it. The script saves
  the previous values and warns when they render differently.

**gVisor** (`install-gvisor.sh`, x86_64 or aarch64):
- `--platforms` — `systrap` (default, works anywhere, RuntimeClass `gvisor`, handler `runsc`) and/or `kvm`
  (RuntimeClass `gvisor-kvm`, handler `runsc-kvm`, needs `/dev/kvm`).
- `--version` — gVisor release like `20261012.0`, default `latest`. `--url-base` for a mirror on air-gapped clusters.

**Both**: `--nodes a,b` limits to named nodes; the default is every node without a NoSchedule/NoExecute taint
(normally the workers). Tainted nodes need chart tolerations added by hand, so steer users to `--nodes` for untainted
ones.

Debug-pod tuning via env vars: `DEBUG_NAMESPACE` (default `kube-system`; must allow privileged pods under Pod
Security), `DEBUG_IMAGE` (default `busybox:1.36`; needs `chroot` and a bz2-capable `tar`; point at a mirror when
air-gapped), `NODE_TIMEOUT` (default 300 s per node command, including image pull).

### 3. Check readiness

```bash
SK=~/.claude/skills/kata-gvisor-install/scripts
$SK/check-prereqs.sh --runtimes kata,gvisor --shims "qemu-runtime-rs qemu" --platforms systrap
```

`--runtimes` is `kata` (default), `gvisor`, or `kata,gvisor`; the gVisor version flag is `--gvisor-version` here.
Show the user the table, then explain each FAIL in plain terms with the fix. Common ones:

- `kvm` FAIL → no hardware/nested virtualisation. Kata can't work; offer gVisor `systrap` instead (it needs no KVM).
- `fc-tools` FAIL → pass `--install-fc-tools` to install-kata.sh (it installs them before re-running the check). If
  the user asked for Firecracker and told you to proceed, that's within scope: it's a standard distro package. Otherwise
  mention it in the plan you confirm. Or drop `fc` from `--shims`.
- `dm-thin` FAIL → the kernel lacks device-mapper thin provisioning. These scripts can't fix that (it needs a
  different node kernel); drop `fc` and say why.
- `pool-space` WARN → lower `--pool-gb` to fit; the file is sparse but grows as images are unpacked.
- `debug-ns` FAIL → set `DEBUG_NAMESPACE` to a namespace whose Pod Security allows privileged pods.
- `node-access` FAIL → the debug pod didn't run (image pull, PSA, timeout): try `DEBUG_IMAGE`/`NODE_TIMEOUT`.
- `containerd-cfg` FAIL (imports line without conf.d) → the user must add `"/etc/containerd/conf.d/*.toml"` to it.

WARNs (low memory, old containerd, no vhost-net) are worth mentioning but don't block. INFO `nested` means the nodes
are VMs themselves: Kata works, but VMs boot slower and each Kata pod takes ~2 GB, so capacity is worth mentioning.

### 4. Dry run and confirm

```bash
$SK/install-kata.sh   --shims "qemu-runtime-rs qemu" --dry-run      # add --install-fc-tools with fc
$SK/install-gvisor.sh --platforms systrap --dry-run
```

Summarise the plan and get an explicit go-ahead before the real run, unless the user already clearly told you to just
install. Mention the side effects: containerd restarts on each target node (running containers survive, but pods
being created at that instant can fail once and get retried), kata-deploy runs as a DaemonSet in `kube-system`, and
binaries/config land on the nodes.

### 5. Install

The install scripts re-run the checks themselves (skip with `--skip-checks` only if you already ran them and nothing
changed). They're idempotent, so re-running after fixing a problem is safe. Kata with several shims can take
several minutes (image pulls, `helm --wait`); run it in the background or with a long timeout and watch the output,
rather than sleeping.

Install order when doing both doesn't matter much; doing Kata first means kata-deploy's containerd restart happens
before gVisor's smoke test.

### 6. Verify and hand over

Each script ends with a smoke test: a busybox pod per RuntimeClass that must show a guest kernel (Kata) or a gVisor
boot in `dmesg` plus the right platform (gVisor). Report the result per RuntimeClass and show
`kubectl get runtimeclass`. Then give the user a snippet for using it:

```yaml
spec:
  runtimeClassName: kata-qemu-runtime-rs   # or kata-qemu, kata-fc, gvisor, gvisor-kvm
```

Quick way to tell which sandbox a pod is in: `kubectl exec <pod> -- uname -r` — Kata shows the guest kernel (differs
from the node's), gVisor shows `4.19.0-gvisor` style output, runc shows the node kernel. For gVisor, `dmesg` inside the
pod prints gVisor's boot messages.

## When something fails

Read `references/troubleshooting.md` — it covers the failure modes these scripts have actually hit (containerd restart
window, Kata agent vsock timeouts, half-created devmapper devices, leftover debug pods, PSA rejections) and how to
undo an install.

## Limits worth stating up front

- containerd only (no CRI-O); systemd nodes only.
- Kata: x86_64 only here; the node kernel must have KVM and vhost-vsock. These scripts report kernel gaps, they can't fix them.
- gVisor aarch64 is supported by the script but untested.
- Tolerations for tainted nodes aren't handled.
- `privileged_without_host_devices = true` is set for the Kata handlers (by kata-deploy) but not for runsc.
