# Docker Client API Methods Reference

Complete method listing for `*client.Client` (github.com/moby/moby/client v0.3.0).

All methods take `context.Context` as the first parameter. All option and result types are in the `client` package.

## Convention

Every method follows this pattern:
- **Input**: `client.{Operation}Options` struct
- **Output**: `client.{Operation}Result` struct (+ `error`)
- **List results**: Result structs have an `.Items` field containing the slice

## Images

| Method | Signature | Result Fields |
|--------|-----------|---------------|
| `ImageList` | `(ctx, ImageListOptions) → ImageListResult` | `.Items []image.Summary` |
| `ImagePull` | `(ctx, ref string, ImagePullOptions) → ImagePullResponse` | `.Wait(ctx)`, `.JSONMessages(ctx)`, `.Close()` |
| `ImagePush` | `(ctx, ref string, ImagePushOptions) → ImagePushResponse` | `.Wait(ctx)`, `.Close()` |
| `ImageBuild` | `(ctx, buildContext io.Reader, ImageBuildOptions) → ImageBuildResult` | `.Body io.ReadCloser` |
| `ImageInspect` | `(ctx, imageID string, ...ImageInspectOption) → ImageInspectResult` | Embeds `image.InspectResponse` |
| `ImageRemove` | `(ctx, imageID string, ImageRemoveOptions) → ImageRemoveResult` | `.Items []image.DeleteResponse` |
| `ImageTag` | `(ctx, source string, target string, ImageTagOptions) → ImageTagResult` | (empty) |
| `ImageHistory` | `(ctx, imageID string, ...ImageHistoryOption) → ImageHistoryResult` | `.Items []image.HistoryResponseItem` |
| `ImageSearch` | `(ctx, term string, ImageSearchOptions) → ImageSearchResult` | `.Items []registry.SearchResult` |
| `ImageSave` | `(ctx, imageIDs []string, ...ImageSaveOption) → ImageSaveResult` | implements `io.ReadCloser` |
| `ImageLoad` | `(ctx, input io.Reader, ...ImageLoadOption) → ImageLoadResult` | implements `io.ReadCloser` |
| `ImagesPrune` | `(ctx, ImagePruneOptions) → ImagePruneResult` | `.ImagesDeleted`, `.SpaceReclaimed` |

## Containers

| Method | Signature | Result Fields |
|--------|-----------|---------------|
| `ContainerCreate` | `(ctx, ContainerCreateOptions) → ContainerCreateResult` | `.ID string`, `.Warnings []string` |
| `ContainerStart` | `(ctx, containerID string, ContainerStartOptions) → ContainerStartResult` | (empty) |
| `ContainerStop` | `(ctx, containerID string, ContainerStopOptions) → ContainerStopResult` | (empty) |
| `ContainerRestart` | `(ctx, containerID string, ContainerRestartOptions) → ContainerRestartResult` | (empty) |
| `ContainerKill` | `(ctx, containerID string, ContainerKillOptions) → ContainerKillResult` | (empty) |
| `ContainerRemove` | `(ctx, containerID string, ContainerRemoveOptions) → ContainerRemoveResult` | (empty) |
| `ContainerList` | `(ctx, ContainerListOptions) → ContainerListResult` | `.Items []container.Summary` |
| `ContainerInspect` | `(ctx, containerID string, ContainerInspectOptions) → ContainerInspectResult` | `.Container container.InspectResponse`, `.Raw json.RawMessage` |
| `ContainerLogs` | `(ctx, containerID string, ContainerLogsOptions) → ContainerLogsResult` | implements `io.ReadCloser` |
| `ContainerWait` | `(ctx, containerID string, ContainerWaitOptions) → ContainerWaitResult` | `.StatusCode()`, `.Err()` |
| `ExecCreate` | `(ctx, containerID string, ExecCreateOptions) → ExecCreateResult` | `.ID string` |
| `ExecAttach` | `(ctx, execID string, ExecAttachOptions) → ExecAttachResult` | `.Conn`, `.Reader`, `.Close()` |
| `ExecInspect` | `(ctx, execID string, ExecInspectOptions) → ExecInspectResult` | `.Running`, `.ExitCode`, `.ProcessConfig` |
| `ContainerTop` | `(ctx, containerID string, ContainerTopOptions) → ContainerTopResult` | `.Titles`, `.Processes` |
| `ContainerStats` | `(ctx, containerID string, ContainerStatsOptions) → ContainerStatsResult` | `.Body io.ReadCloser`, `.OSType` |
| `ContainerRename` | `(ctx, containerID string, ContainerRenameOptions) → ContainerRenameResult` | (empty) |
| `ContainerPause` | `(ctx, containerID string, ContainerPauseOptions) → ContainerPauseResult` | (empty) |
| `ContainerUnpause` | `(ctx, containerID string, ContainerUnpauseOptions) → ContainerUnpauseResult` | (empty) |
| `ContainerAttach` | `(ctx, containerID string, ContainerAttachOptions) → ContainerAttachResult` | `.Conn`, `.Reader`, `.Close()` |
| `CopyFromContainer` | `(ctx, containerID string, CopyFromContainerOptions) → CopyFromContainerResult` | `.Body io.ReadCloser`, `.Stat` |
| `CopyToContainer` | `(ctx, containerID string, CopyToContainerOptions) → CopyToContainerResult` | (empty) |
| `ContainersPrune` | `(ctx, ContainerPruneOptions) → ContainerPruneResult` | `.ContainersDeleted`, `.SpaceReclaimed` |

### ContainerCreateOptions fields

```go
type ContainerCreateOptions struct {
    Config           *container.Config
    HostConfig       *container.HostConfig
    NetworkingConfig *network.NetworkingConfig
    Platform         *ocispec.Platform
    Name             string
    Image            string  // shortcut for Config.Image
}
```

### ExecCreateOptions fields

```go
type ExecCreateOptions struct {
    User, WorkingDir, DetachKeys string
    Cmd                          []string
    Env                          []string
    Privileged, TTY              bool
    AttachStdin, AttachStdout, AttachStderr bool
}
```

## Networks

| Method | Signature | Result Fields |
|--------|-----------|---------------|
| `NetworkList` | `(ctx, NetworkListOptions) → NetworkListResult` | `.Items []network.Summary` |
| `NetworkCreate` | `(ctx, name string, NetworkCreateOptions) → NetworkCreateResult` | `.ID string`, `.Warning []string` |
| `NetworkRemove` | `(ctx, networkID string, NetworkRemoveOptions) → NetworkRemoveResult` | (empty) |
| `NetworkInspect` | `(ctx, networkID string, NetworkInspectOptions) → NetworkInspectResult` | `.NetworkResource` |
| `NetworkConnect` | `(ctx, networkID string, NetworkConnectOptions) → NetworkConnectResult` | (empty) |
| `NetworkDisconnect` | `(ctx, networkID string, NetworkDisconnectOptions) → NetworkDisconnectResult` | (empty) |
| `NetworksPrune` | `(ctx, NetworkPruneOptions) → NetworkPruneResult` | `.NetworksDeleted` |

## Volumes

| Method | Signature | Result Fields |
|--------|-----------|---------------|
| `VolumeList` | `(ctx, VolumeListOptions) → VolumeListResult` | `.Items []volume.Volume`, `.Warnings` |
| `VolumeCreate` | `(ctx, VolumeCreateOptions) → VolumeCreateResult` | `.Volume` |
| `VolumeRemove` | `(ctx, volumeID string, VolumeRemoveOptions) → VolumeRemoveResult` | (empty) |
| `VolumeInspect` | `(ctx, volumeID string, VolumeInspectOptions) → VolumeInspectResult` | `.Volume` |
| `VolumesPrune` | `(ctx, VolumePruneOptions) → VolumePruneResult` | `.VolumesDeleted`, `.SpaceReclaimed` |

## System

| Method | Signature | Result Fields |
|--------|-----------|---------------|
| `Ping` | `(ctx, PingOptions) → PingResult` | `.APIVersion`, `.OSType`, `.Experimental` |
| `Info` | `(ctx, InfoOptions) → SystemInfoResult` | `.Info system.Info` |
| `DiskUsage` | `(ctx, DiskUsageOptions) → DiskUsageResult` | `.Images`, `.Containers`, `.Volumes`, `.BuildCache` |
| `Events` | `(ctx, EventsListOptions) → EventsResult` | `.Messages()` iterator |
| `ServerVersion` | `(ctx, ServerVersionOptions) → ServerVersionResult` | `.Version`, `.APIVersion`, `.GoVersion` |

## Filters

Filters are a `client.Filters` type (defined in the client package):

```go
f := client.Filters{}.Add("status", "running")
result, err := cli.ContainerList(ctx, client.ContainerListOptions{Filters: f})
```

Do NOT use `filters.NewArgs()` from `api/types/filters` — that is the old API.
