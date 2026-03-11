---
name: labctl-playground
description: Create, manage, and interact with iximiuz Labs playgrounds using labctl. Use this skill whenever the task involves spinning up a clean testing environment, running commands on remote lab machines, deploying and testing applications in isolated VMs, or performing security research in sandboxed infrastructure. Triggers on mentions of labctl, iximiuz, lab playgrounds, needing a fresh Linux/Docker/Kubernetes environment for testing, wanting to test code on a remote machine, or setting up infrastructure for penetration testing or application deployment. Also use when the user wants to copy files to/from a remote lab, forward ports to a running playground, or clean up lab resources.
---

# labctl Playground

Use `labctl` to create and manage clean, isolated testing environments (playgrounds) hosted by iximiuz Labs. Each playground is a set of cloud VMs with pre-installed tooling, networked together and accessible via SSH.

## Prerequisites

- `labctl` installed and on PATH
- Authenticated session (`labctl auth whoami` should return a userId)

If not authenticated, run `labctl auth login` and follow the browser flow.

## Choosing a Playground

Pick the playground that matches the task. The catalog is available via `labctl playground catalog`, but here's a quick guide:

### Linux distros (general purpose)
| Playground | Use for |
|---|---|
| `ubuntu-24-04` | General testing, modern Ubuntu |
| `ubuntu-22-04` | When 22.04 compatibility is needed |
| `debian-stable` | Stable Debian environment |
| `kali-linux` | Security testing and penetration testing (comes with security tools pre-installed) |
| `alpine` | Minimal Linux environment |
| `fedora`, `almalinux`, `rockylinux` | RHEL-family testing |
| `archlinux`, `opensuse-tumbleweed` | Rolling release distros |

### Containers
| Playground | Use for |
|---|---|
| `docker` | Single machine with Docker engine (4 CPU, 8GB RAM) |
| `podman` | Rootless container workflows |
| `nerdctl` | containerd-based container management |
| `incus` | System containers and VMs |

### Kubernetes
| Playground | Use for |
|---|---|
| `k3s` | Multi-node K3s cluster (dev-machine + control-plane + 2 workers) |
| `k3s-bare` | Bare K3s without extras |
| `k0s` | k0s-based Kubernetes cluster |
| `k8s-client-go` | Kubernetes Go client development |

### Networking
| Playground | Use for |
|---|---|
| `mini-lan-ubuntu` | 4 Ubuntu nodes on a shared network |
| `mini-lan-ubuntu-docker` | 4 Ubuntu+Docker nodes on a shared network |

### Languages / Development
| Playground | Use for |
|---|---|
| `golang` | Go development environment |
| `python` | Python development environment |
| `nodejs` | Node.js development environment |
| `zig` | Zig development environment |
| `coding-agent-base` | General-purpose coding agent base |

### Other
| Playground | Use for |
|---|---|
| `docker-swarm` | Docker Swarm orchestration |
| `dagger` | Dagger CI/CD pipelines |
| `kamal` | Kamal deployment tool |
| `tetragon` | Cilium Tetragon security observability |
| `mintoolkit` | Container minification |

**When in doubt:** `docker` is a solid default for most tasks. Use `kali-linux` for security work. Use `k3s` for anything Kubernetes-related.

## Full Lifecycle

### 1. Check for existing playgrounds first

Before creating a new playground, check if there's already one running that could be reused:

```bash
labctl playground list
```

This avoids wasting resources. If a suitable playground is already running, use it.

### 2. Start a playground

```bash
labctl playground start <playground-name> --quiet
```

The `--quiet` flag prints only the playground ID, which is what you need for all subsequent commands. Capture it:

```bash
PLAYGROUND_ID=$(labctl playground start docker --quiet)
```

Starting a playground takes 30-90 seconds. The command blocks until the playground is initialized and ready.

Useful flags:
- `--ssh` — SSH into the playground immediately after start
- `--machine <name>` — Target a specific machine when using `--ssh` (for multi-machine playgrounds like k3s)
- `--open` — Open the playground in a browser

### 3. Run commands on the playground

This is the primary way to interact with a running playground. Use `labctl ssh` to execute commands remotely:

```bash
# Interactive shell
labctl ssh $PLAYGROUND_ID

# Execute a single command
labctl ssh $PLAYGROUND_ID -- ls -la /

# Execute a command on a specific machine (multi-machine playgrounds)
labctl ssh $PLAYGROUND_ID --machine node-01 -- hostname

# Run as root
labctl ssh $PLAYGROUND_ID --user root -- apt-get update
```

For running multi-line scripts or complex commands, write a script locally, copy it to the playground, then execute it:

```bash
labctl cp ./setup.sh $PLAYGROUND_ID:~/setup.sh
labctl ssh $PLAYGROUND_ID -- chmod +x ~/setup.sh
labctl ssh $PLAYGROUND_ID -- ~/setup.sh
```

Alternatively, pipe commands through ssh:

```bash
labctl ssh $PLAYGROUND_ID -- bash -c 'apt-get update && apt-get install -y nmap'
```

### 4. Copy files to and from the playground

```bash
# Copy a local file to the playground
labctl cp ./exploit.py $PLAYGROUND_ID:~/exploit.py

# Copy a local directory to the playground (recursive)
labctl cp -r ./my-app $PLAYGROUND_ID:~/my-app

# Copy results back from the playground
labctl cp $PLAYGROUND_ID:~/results.txt ./results.txt

# Copy from a specific machine
labctl cp -m node-01 $PLAYGROUND_ID:/var/log/syslog ./syslog.txt
```

### 5. Port forwarding

Forward ports between your local machine and the playground to access services running in the lab:

```bash
# Forward local port 8080 to playground port 80 (access playground's port 80 at localhost:8080)
labctl port-forward $PLAYGROUND_ID -L 8080:80

# Forward playground's port 3000 to local port 3000
labctl port-forward $PLAYGROUND_ID -L 3000:3000

# Forward to a specific machine
labctl port-forward $PLAYGROUND_ID -m node-01 -L 6443:6443

# Remote forwarding (make a local service available in the playground)
labctl port-forward $PLAYGROUND_ID -R 9090:localhost:9090
```

Port forwarding runs in the foreground. Run it in the background if you need to continue working:

```bash
labctl port-forward $PLAYGROUND_ID -L 8080:80 &
```

### 6. Expose services publicly

Make a playground service accessible via a public URL:

```bash
# Expose a port with a public URL
labctl expose port $PLAYGROUND_ID 8080

# Expose a web terminal
labctl expose shell $PLAYGROUND_ID

# List exposed services
labctl expose list $PLAYGROUND_ID
```

### 7. List playground machines

For multi-machine playgrounds, see what's available:

```bash
labctl playground machines $PLAYGROUND_ID
```

### 8. Stop and restart

Stop preserves state for later use. Restart resumes a stopped playground:

```bash
labctl playground stop $PLAYGROUND_ID
labctl playground restart $PLAYGROUND_ID
```

### 9. Destroy (cleanup)

When finished, always destroy the playground to free resources:

```bash
labctl playground destroy $PLAYGROUND_ID
```

This permanently deletes the playground and all its data. Use `stop` instead if you want to come back to it later.

## Cleanup Discipline

Playgrounds consume cloud resources. Follow these rules:

- **Always destroy playgrounds when the task is complete.** Don't leave them running.
- **Before starting a new playground**, run `labctl playground list` to check for existing ones.
- **If a task fails or is abandoned**, still destroy the playground.
- **Use `labctl playground list --all`** to find stopped playgrounds that should be cleaned up.

## Common Workflows

### Security testing

```bash
# Start a Kali playground
PLAYGROUND_ID=$(labctl playground start kali-linux --quiet)

# Copy attack scripts
labctl cp -r ./scripts $PLAYGROUND_ID:~/scripts

# Run tools
labctl ssh $PLAYGROUND_ID -- ~/scripts/scan.sh

# Retrieve results
labctl cp $PLAYGROUND_ID:~/results ./results

# Clean up
labctl playground destroy $PLAYGROUND_ID
```

### Testing an application

```bash
# Start a Docker playground
PLAYGROUND_ID=$(labctl playground start docker --quiet)

# Copy the application
labctl cp -r ./my-app $PLAYGROUND_ID:~/my-app

# Build and run
labctl ssh $PLAYGROUND_ID -- bash -c 'cd ~/my-app && docker build -t myapp . && docker run -d -p 8080:8080 myapp'

# Forward port to test locally
labctl port-forward $PLAYGROUND_ID -L 8080:8080

# Clean up
labctl playground destroy $PLAYGROUND_ID
```

### Kubernetes testing

```bash
# Start a K3s cluster
PLAYGROUND_ID=$(labctl playground start k3s --quiet)

# Apply manifests from the dev-machine
labctl cp ./manifests $PLAYGROUND_ID:~/manifests
labctl ssh $PLAYGROUND_ID -- kubectl apply -f ~/manifests/

# Check status
labctl ssh $PLAYGROUND_ID -- kubectl get pods -A

# Clean up
labctl playground destroy $PLAYGROUND_ID
```

## Troubleshooting

- **"not authenticated" errors** — Run `labctl auth login`
- **Playground start hangs** — Check your internet connection; playgrounds are cloud-hosted
- **SSH connection refused** — The playground may still be initializing; wait a few seconds and retry
- **Command not found on playground** — Install it via the package manager (`apt-get`, `dnf`, etc.) or pick a playground that has the tool pre-installed
- **Can't reach services between machines** — Machines in the same playground share a network (typically `172.16.0.0/24`); use `labctl playground machines` to see IP addresses
