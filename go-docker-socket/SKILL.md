---
name: go-docker-socket
description: >
  Guide for writing Go programs that interact with the Docker daemon via the Docker socket.
  Use when building Go code that needs to: list/inspect/pull/remove Docker images, list/create/start/stop/remove containers,
  manage networks or volumes, exec commands in containers, stream container logs, or perform any other Docker Engine API
  operation from Go. Triggers on requests involving Go + Docker, Go + containers, or Go + Docker socket.
---

# Go Docker Socket Interaction

## Dependencies

Use the Moby client library (the official Docker Engine Go client):

```
github.com/moby/moby/client
github.com/moby/moby/api
```

Add to a Go module:
```bash
go get github.com/moby/moby/client@latest github.com/moby/moby/api@latest
```


## IMPORTANT: API conventions

All option and result types live in the `client` package (NOT in `api/types/*` sub-packages). The naming convention is:

- Options: `client.{Operation}Options` (e.g. `client.ContainerListOptions`, `client.ImagePullOptions`)
- Results: `client.{Operation}Result` (e.g. `client.ContainerListResult`, `client.ImageListResult`)

List operations return a **Result struct** with an `.Items` field, NOT a bare slice:
```go
result, err := cli.ContainerList(ctx, client.ContainerListOptions{})
// result.Items is []container.Summary — iterate over result.Items, NOT result directly
```

## Client Initialization

Always use `FromEnv` + `WithAPIVersionNegotiation()`:

```go
import "github.com/moby/moby/client"

cli, err := client.NewClientWithOpts(client.FromEnv, client.WithAPIVersionNegotiation())
if err != nil {
    return fmt.Errorf("creating docker client: %w", err)
}
defer cli.Close()
```

- `FromEnv` reads `DOCKER_HOST`, `DOCKER_TLS_VERIFY`, `DOCKER_CERT_PATH`. Defaults to `/var/run/docker.sock`.
- `WithAPIVersionNegotiation()` auto-negotiates the API version with the daemon — always include this.
- Always `defer cli.Close()`.

## Common Operations

All API methods take a `context.Context` as their first argument. Use `context.Background()` for simple tools or pass through a caller-provided context.

### Images

```go
// List images — returns ImageListResult with .Items field
result, err := cli.ImageList(ctx, client.ImageListOptions{All: true})
for _, img := range result.Items {
    fmt.Println(img.ID)
}

// Pull an image — returns ImagePullResponse interface; call .Wait() to block until done
pullResp, err := cli.ImagePull(ctx, "docker.io/library/nginx:latest", client.ImagePullOptions{})
if err != nil { ... }
err = pullResp.Wait(ctx) // blocks until pull completes
pullResp.Close()

// Inspect an image — uses variadic options
inspect, err := cli.ImageInspect(ctx, "nginx:latest")
// inspect.ID, inspect.RepoTags, etc.

// Remove an image
removeResult, err := cli.ImageRemove(ctx, "nginx:latest", client.ImageRemoveOptions{Force: true})
// removeResult.Items contains []image.DeleteResponse
```

### Containers

```go
import (
    "github.com/moby/moby/api/types/container"
    "github.com/moby/moby/api/types/network"
)

// Create a container — single options struct
createResult, err := cli.ContainerCreate(ctx, client.ContainerCreateOptions{
    Config: &container.Config{
        Image: "nginx:latest",
        Cmd:   []string{"nginx", "-g", "daemon off;"},
    },
    HostConfig: &container.HostConfig{
        PortBindings: nat.PortMap{
            "80/tcp": []nat.PortBinding{{HostPort: "8080"}},
        },
    },
    NetworkingConfig: &network.NetworkingConfig{},
    Name: "my-container",
})
// createResult.ID is the container ID

// Start / Stop / Remove — all take containerID + client.*Options, return client.*Result
cli.ContainerStart(ctx, createResult.ID, client.ContainerStartOptions{})
cli.ContainerStop(ctx, containerID, client.ContainerStopOptions{})
cli.ContainerRemove(ctx, containerID, client.ContainerRemoveOptions{Force: true})

// List containers — returns ContainerListResult with .Items
listResult, err := cli.ContainerList(ctx, client.ContainerListOptions{All: true})
for _, c := range listResult.Items {
    fmt.Printf("ID: %s Image: %s\n", c.ID[:12], c.Image)
}

// Inspect — returns ContainerInspectResult
inspectResult, err := cli.ContainerInspect(ctx, containerID, client.ContainerInspectOptions{})
// inspectResult.Container has the full container info

// Logs — returns ContainerLogsResult (implements io.ReadCloser)
logs, err := cli.ContainerLogs(ctx, containerID, client.ContainerLogsOptions{
    ShowStdout: true, ShowStderr: true, Follow: false,
})
defer logs.Close()
```

### Exec in Container

```go
execCreate, err := cli.ExecCreate(ctx, containerID, client.ExecCreateOptions{
    Cmd:          []string{"ls", "-la"},
    AttachStdout: true,
    AttachStderr: true,
})
// execCreate.ID is the exec instance ID

execAttach, err := cli.ExecAttach(ctx, execCreate.ID, client.ExecAttachOptions{})
defer execAttach.Close()
// Read execAttach.Reader for output (multiplexed stream — use stdcopy.StdCopy)

import "github.com/moby/moby/api/pkg/stdcopy"
stdcopy.StdCopy(os.Stdout, os.Stderr, execAttach.Reader)
```

### Networks and Volumes

```go
// List networks — returns NetworkListResult with .Items
netResult, err := cli.NetworkList(ctx, client.NetworkListOptions{})
for _, n := range netResult.Items {
    fmt.Println(n.Name)
}

// Create network
cli.NetworkCreate(ctx, "my-net", client.NetworkCreateOptions{Driver: "bridge"})

// List volumes — returns VolumeListResult with .Items
volResult, err := cli.VolumeList(ctx, client.VolumeListOptions{})
for _, v := range volResult.Items {
    fmt.Println(v.Name)
}
```

For the full API surface, see [references/api_methods.md](references/api_methods.md).

## Key Patterns

- **Option/Result structs in `client` package**: ALL methods use `client.{Op}Options` for input and `client.{Op}Result` for output. Do NOT import option types from `api/types/container`, `api/types/network`, etc. — those are for Config structs only.
- **Result wrappers for lists**: `ContainerList`, `ImageList`, `NetworkList`, `VolumeList` all return `*Result` structs. Access the items via `.Items`.
- **Streaming responses**: `ImagePull` returns `ImagePullResponse` — call `.Wait(ctx)` to block until complete, or `.JSONMessages(ctx)` to iterate status messages. `ContainerLogs` returns `ContainerLogsResult` (an `io.ReadCloser`). `ExecAttach` returns `ExecAttachResult` with `.Reader`.
- **Multiplexed streams**: For container logs and exec output, use `github.com/moby/moby/api/pkg/stdcopy.StdCopy` to demux stdout/stderr. Note: stdcopy is in the `api` module, NOT the old monolithic `moby/moby` package.
- **Filters**: Use `client.Filters` (a map type in the `client` package):
  ```go
  f := client.Filters{}.Add("status", "running")
  result, err := cli.ContainerList(ctx, client.ContainerListOptions{Filters: f})
  ```
- **Error handling**: Wrap errors with context (`fmt.Errorf("doing X: %w", err)`). Check `errdefs.IsNotFound(err)` from `github.com/containerd/errdefs` for 404-type errors.

## Complete Example: List Running Containers

This is a full, compilable program:

```go
package main

import (
	"context"
	"fmt"
	"os"

	"github.com/moby/moby/client"
)

func main() {
	cli, err := client.NewClientWithOpts(client.FromEnv, client.WithAPIVersionNegotiation())
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating Docker client: %v\n", err)
		os.Exit(1)
	}
	defer cli.Close()

	ctx := context.Background()

	result, err := cli.ContainerList(ctx, client.ContainerListOptions{})
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error listing containers: %v\n", err)
		os.Exit(1)
	}

	if len(result.Items) == 0 {
		fmt.Println("No running containers found.")
		return
	}

	for _, c := range result.Items {
		fmt.Printf("ID: %s, Image: %s, Status: %s\n", c.ID[:12], c.Image, c.Status)
	}
}
```

## Complete Example: Pull, Run, Exec, Cleanup

This is a full, compilable program that pulls an image, creates a container, executes a command, and cleans up:

```go
package main

import (
	"context"
	"fmt"
	"os"

	"github.com/moby/moby/api/types/container"
	"github.com/moby/moby/client"
	"github.com/moby/moby/api/pkg/stdcopy"
)

func main() {
	ctx := context.Background()

	cli, err := client.NewClientWithOpts(client.FromEnv, client.WithAPIVersionNegotiation())
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating Docker client: %v\n", err)
		os.Exit(1)
	}
	defer cli.Close()

	// Pull image
	pullResp, err := cli.ImagePull(ctx, "alpine:latest", client.ImagePullOptions{})
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error pulling image: %v\n", err)
		os.Exit(1)
	}
	if err := pullResp.Wait(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "Error waiting for pull: %v\n", err)
		os.Exit(1)
	}
	pullResp.Close()

	// Create container
	createResult, err := cli.ContainerCreate(ctx, client.ContainerCreateOptions{
		Config: &container.Config{
			Image: "alpine:latest",
			Cmd:   []string{"sleep", "30"},
		},
		Name: "example-container",
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating container: %v\n", err)
		os.Exit(1)
	}

	// Start container
	if _, err := cli.ContainerStart(ctx, createResult.ID, client.ContainerStartOptions{}); err != nil {
		fmt.Fprintf(os.Stderr, "Error starting container: %v\n", err)
		os.Exit(1)
	}

	// Exec a command
	execCreate, err := cli.ExecCreate(ctx, createResult.ID, client.ExecCreateOptions{
		Cmd:          []string{"echo", "hello from container"},
		AttachStdout: true,
		AttachStderr: true,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating exec: %v\n", err)
		os.Exit(1)
	}

	execAttach, err := cli.ExecAttach(ctx, execCreate.ID, client.ExecAttachOptions{})
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error attaching to exec: %v\n", err)
		os.Exit(1)
	}
	stdcopy.StdCopy(os.Stdout, os.Stderr, execAttach.Reader)
	execAttach.Close()

	// Stop and remove container
	cli.ContainerStop(ctx, createResult.ID, client.ContainerStopOptions{})
	cli.ContainerRemove(ctx, createResult.ID, client.ContainerRemoveOptions{Force: true})

	fmt.Println("Done.")
}
```
