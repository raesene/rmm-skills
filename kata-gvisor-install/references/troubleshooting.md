# Troubleshooting the Kata / gVisor installs

Failure modes these scripts have hit on real clusters, and what to do. Node commands below can be run the same way
the scripts do it, with no SSH:

```bash
kubectl debug node/<node> -n kube-system --profile=sysadmin --image=busybox:1.36 -it -- chroot /host bash
```

(Delete the `node-debugger-*` pod afterwards.)

## Sandboxes fail right after an install

kata-deploy restarts containerd on every node when installed or upgraded, and install-gvisor.sh restarts it when the
handler config changes. Pods created during that window fail with `EOF`, `tun set iff: EBUSY` or "failed to set up
network". install-kata.sh waits for `rollout status ds/kata-deploy` plus 20 s; if a smoke test still fails this way,
just re-run the script — it's idempotent.

## Kata (runtime-rs) pod fails with "vsock ... within 10s"

The Rust runtime gives the guest agent `[agent.kata] reconnect_timeout_ms` to come up — 3000 ms by Kata's default,
too short for nested VMs or busy nodes. install-kata.sh sets 45 s through the shim's `dropIn` (`--agent-timeout`); if
it still fails, raise it (`--agent-timeout 90`) and re-run the script. Don't fix it with a hand-run
`helm upgrade --set ...dropIn`: the next run of install-kata.sh replaces the release's values. Check the setting
landed on the node: `cat /opt/kata/share/defaults/kata-containers/runtime-rs/config.d/50-user-overrides.toml`
(path may vary by version: `find /opt/kata -name '50-user-overrides.toml'`). If it fails even with a long timeout, check
`/dev/vhost-vsock` on the node and node memory (each guest takes 2 GB by default).

## Kata pod reports the node's kernel

The smoke test FAILs with "pod reports the node's own kernel". The RuntimeClass handler isn't mapped to a Kata shim in
containerd. Check `kubectl -n kube-system logs ds/kata-deploy` and that `/etc/containerd/config.toml` on the node
picked up kata-deploy's drop-in (`containerd config dump | grep kata`).

## Firecracker (fc): "already there ... State:Deactivating"

A half-created devmapper thin device blocks every later one. Clean up on the node **with containerd stopped**:

```bash
systemctl stop containerd
dmsetup ls | grep containerd-thinpool-snap      # find the stuck device(s)
dmsetup remove <dev>
dmsetup message containerd-thinpool 0 "delete <id>"   # <id> = the snapshot's device id
rm /var/lib/containerd/io.containerd.snapshotter.v1.devmapper/metadata.db
systemctl start containerd
```

This throws away all devmapper snapshots on that node (images are re-unpacked on next use). Ask before doing it.

## fc: "/dev/mapper/containerd-thinpool-snap-N does not exist"

The node has no udev. install-kata.sh sets LVM `udev_sync/udev_rules = 0` and a containerd drop-in with
`DM_DISABLE_UDEV=1` when systemd-udevd isn't active; if the node gained/lost udev afterwards, re-run the script or
check `/etc/systemd/system/containerd.service.d/dm-no-udev.conf`.

## Debug pods don't run

- Rejected at admission → `DEBUG_NAMESPACE` enforces a Pod Security level other than `privileged`. Pick another namespace.
- `ImagePullBackOff` → air-gapped or rate-limited; set `DEBUG_IMAGE` to a mirrored busybox (needs `chroot` and a tar with bz2).
- Timeout → raise `NODE_TIMEOUT`.
- A script killed hard can leave `node-debugger-*` pods: `kubectl -n <ns> get pods | grep node-debugger` and delete them.

## gVisor: smoke test shows the wrong platform

`gvisor-kvm` running as systrap means the shim didn't read `/etc/containerd/runsc/runsc-kvm.toml`. Check the
`runsc-kvm` handler's `ConfigPath` in `/etc/containerd/conf.d/gvisor.toml` and that the file says `platform = "kvm"`.

## gVisor: runsc download fails

Wrong `--version` (use the release date form, e.g. `20261012.0`) or no egress from the node: mirror
`<url-base>/<version>/<arch>/gvisor.tar.bz2` and `.sha512` and pass `--url-base`. The node's own curl/wget does the
download (busybox wget is avoided because it doesn't validate TLS).

## Undoing an install

Confirm with the user first; workloads using these RuntimeClasses will stop scheduling.

Kata:
```bash
helm -n kube-system uninstall kata-deploy
kubectl label nodes --all katacontainers.io/install- katacontainers.io/kata-runtime-
```
The chart is meant to clean up the nodes on uninstall (not verified with these scripts): afterwards check that
`/opt/kata` and `/etc/containerd/conf.d/kata-deploy.toml` are gone and the `kata-*` RuntimeClasses deleted.
The fc thin pool (`containerd` VG, `/var/lib/containerd-thinpool.img`, `containerd-thinpool.service`,
`/etc/containerd/conf.d/devmapper.toml`) stays; remove it by hand on each node if wanted.

gVisor:
```bash
kubectl delete runtimeclass gvisor gvisor-kvm --ignore-not-found
kubectl label nodes --all runtime.gvisor-
# on each node:
rm /etc/containerd/conf.d/gvisor.toml /etc/containerd/runsc/runsc-kvm.toml
systemctl restart containerd
rm -rf /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1 /usr/local/bin/gvisor-bin
```
If the install added a conf.d import to `config.toml`, a backup `config.toml.bak-gvisor-<timestamp>` sits next to it.
