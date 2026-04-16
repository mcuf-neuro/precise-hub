# Container Deployment (Podman)

Alternative deployment method using a rootless Podman container. For the recommended systemd-based deployment, see the main [README](../README.md).

## Architecture

Storage volumes are mounted on the **host VM** (as root). The container runs **rootless and unprivileged**, receiving the mounted directories as bind-mounts. The host handles network/storage, the container handles data processing.

```
Host VM (root)                    Container (rootless)
┌──────────────────────┐          ┌──────────────────────────┐
│ mount -t davfs  DEG ─┼── -v ───▶│ /mnt/deg                 │
│ mount -t cifs   DL  ─┼── -v ───▶│ /mnt/data-lake           │
│ mount -t cifs   FS  ─┼── -v ───▶│ /mnt/forschungsspeicher  │
└──────────────────────┘          │                          │
                                  │ deploy/run-deploy-loop   │
                                  │ fetch/run-fetch-loop     │
                                  └──────────────────────────┘
```

## Prerequisites

- Podman installed: `sudo apt install podman`
- Storage volumes mounted on the host (see main README)

## Build

```bash
podman build -t precise-hub_img .
```

## Run

```bash
podman run -d \
  -v /mnt/deg:/mnt/deg \
  -v /mnt/data-lake:/mnt/data-lake \
  -v /mnt/forschungsspeicher:/mnt/forschungsspeicher \
  --name precise-hub_cont precise-hub_img
```

The container verifies the bind-mounts are present and starts both processing loops (deploy and fetch).

## Operations

```bash
# View live container logs
podman logs -f precise-hub_cont

# Run a single deploy cycle (for testing)
podman exec precise-hub_cont /opt/precise-hub/process/deploy/process-uploads.sh

# Run a single fetch cycle (for testing)
podman exec precise-hub_cont /opt/precise-hub/process/fetch/process-fetch-requests.sh

# Interactive shell
podman exec -it precise-hub_cont bash

# Stop / start / restart
podman stop precise-hub_cont
podman start precise-hub_cont

# Remove and recreate
podman rm -f precise-hub_cont
podman run -d \
  -v /mnt/deg:/mnt/deg \
  -v /mnt/data-lake:/mnt/data-lake \
  -v /mnt/forschungsspeicher:/mnt/forschungsspeicher \
  --name precise-hub_cont precise-hub_img
```

## Troubleshooting

| Problem | Check |
|---------|-------|
| Container says mount missing | Ensure host mounts are up: `df -h \| grep /mnt` |
| Container won't start | `podman logs precise-hub_cont` — look for bind-mount errors |
| Deploy not running | `podman exec precise-hub_cont cat /tmp/precise-deploy.lock` |
| Fetch not running | `podman exec precise-hub_cont cat /tmp/precise-fetch.lock` |
