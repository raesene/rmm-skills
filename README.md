# RMM Skills

This is a repository where I put any [agent skills](https://agentskills.io/home) I've created that seem like they might be useful.

## Skills

 - kind-audit-cluster - This skill is designed to explain to agents how to create a [kind](https://kind.sigs.k8s.io/) cluster that has Kubernetes auditing enabled. The reason for the skill is that it's mildly tricky to get the volume mounts right and agents often get it wrong.
 - kubelet-exploit - Guides agents through exploiting an unauthenticated read-write Kubernetes kubelet API (port 10250) to retrieve the cluster CA private key. Works on hardened clusters with distroless containers by using techniques like the tab trick for shell builtins and direct etcd manipulation via protobuf-encoded writes. Includes an automated exploit script and detailed manual steps. For authorized security testing only.
 - labctl-playground - Guides agents through the full lifecycle of [iximiuz Labs](https://labs.iximiuz.com/) playgrounds using `labctl`. Covers playground selection, starting environments, running commands via SSH, file transfer, port forwarding, and cleanup. Useful for testing applications in clean environments and security research.
