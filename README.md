# PRECISE Hub

Data management hub for the PRECISE consortium. Runs on a mainstream GNU/Linux system with systemd.

The hub connects three storage systems:
- **Data Exchange Gateway (DEG)** — WebDAV server in the DMZ where external partners upload and download data packages
- **Forschungsspeicher** — CIFS/AD research storage for UKF local data imports
- **Data Lake** — TrueNAS/CIFS long-term storage for all consortium data

Two independent processing loops run continuously:
- **Deploy** — scans for uploaded data packages, validates, extracts, and stores them in the data lake
- **Fetch** — scans for data fetch requests, assembles packages from the data lake, and delivers them to the DEG

## Architecture

Storage volumes are mounted on the host VM. The processing scripts run directly on the host, supervised by systemd.

```
Host VM
┌──────────────────────────────────────────────────────────┐
│ mount -t davfs  DEG ──────────▶ /mnt/deg                │
│ mount -t cifs   DL  ──────────▶ /mnt/data-lake          │
│ mount -t cifs   FS  ──────────▶ /mnt/forschungsspeicher │
│                                                          │
│ systemd                                                  │
│ ├── precise-hub-deploy.service                           │
│ │   └── deploy/run-deploy-loop.sh                        │
│ │       (scan, validate, extract, shard, log)            │
│ └── precise-hub-fetch.service                            │
│     └── fetch/run-fetch-loop.sh                          │
│         (scan requests, assemble, transfer, log)         │
└──────────────────────────────────────────────────────────┘
```

## Script Layout

```
scripts/process/
├── config.sh              # shared configuration
├── logging.sh             # shared JSON logging functions
├── validation.sh          # shared validation functions
├── messages.sh            # shared partner-visible status messages
├── deploy/
│   ├── run-deploy-loop.sh         # deploy processing loop
│   └── process-uploads.sh         # upload processing logic
└── fetch/
    ├── run-fetch-loop.sh          # fetch processing loop
    └── process-fetch-requests.sh  # fetch request processing logic
```

## Prerequisites

- Mainstream GNU/Linux distro with systemd
- Mount tools: `sudo apt install cifs-utils davfs2`
- Runtime dependencies: `sudo apt install -y jq zstd rsync unzip zip`
- Network access to all three storage servers
- Credentials for each storage system

## Quick Start

### 1. Configure Credentials

```bash
cp .env.example .env
# Edit .env and fill in all values (3 services × username/password/path)
```

Keep `.env` readable only by root:
```bash
sudo chown root:root .env
sudo chmod 600 .env
```

### 2. Configure WebDAV

Disable locking for the WebDAV mount (required for davfs2):
```bash
echo "use_locks 0" | sudo tee -a /etc/davfs2/davfs2.conf
```

### 3. Mount Storage Volumes

```bash
# Source credentials and mount all shares
sudo bash -c 'set -a && source .env && ./scripts/host/mount-all.sh'
```

Verify mount status:
```bash
sudo ./scripts/host/test-mounts.sh
```

### 4. Install the Hub

```bash
cd /opt
sudo git clone <repo-url> precise-hub
sudo chown -R neuro:neuro /opt/precise-hub
chmod +x /opt/precise-hub/scripts/process/deploy/*.sh
chmod +x /opt/precise-hub/scripts/process/fetch/*.sh
```

Or symlink from an existing checkout:
```bash
sudo ln -s /home/neuro/precise-hub /opt/precise-hub
```

### 5. Test a Single Processing Cycle

```bash
# Test deploy (upload processing)
/opt/precise-hub/scripts/process/deploy/process-uploads.sh

# Test fetch (request processing)
/opt/precise-hub/scripts/process/fetch/process-fetch-requests.sh
```

### 6. Install systemd Services

**Deploy service** (upload processing):
```bash
sudo tee /etc/systemd/system/precise-hub-deploy.service << 'EOF'
[Unit]
Description=PRECISE Hub Deploy Processor
After=network-online.target remote-fs.target
Wants=network-online.target

[Service]
Type=simple
User=neuro
ExecStart=/opt/precise-hub/scripts/process/deploy/run-deploy-loop.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
```

**Fetch service** (request processing):
```bash
sudo tee /etc/systemd/system/precise-hub-fetch.service << 'EOF'
[Unit]
Description=PRECISE Hub Fetch Processor
After=network-online.target remote-fs.target
Wants=network-online.target

[Service]
Type=simple
User=neuro
ExecStart=/opt/precise-hub/scripts/process/fetch/run-fetch-loop.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
```

Enable and start both:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now precise-hub-deploy.service
sudo systemctl enable --now precise-hub-fetch.service
```

## Operations

```bash
# Check status
systemctl status precise-hub-deploy
systemctl status precise-hub-fetch

# View live logs
journalctl -u precise-hub-deploy -f
journalctl -u precise-hub-fetch -f

# View processing logs on the data lake
ls -lt /mnt/data-lake/logs/ | head -20
tail -f /mnt/data-lake/logs/*.log

# Stop/restart individually
sudo systemctl stop precise-hub-fetch
sudo systemctl restart precise-hub-deploy

# Stop and disable (prevent auto-start on boot)
sudo systemctl disable --now precise-hub-deploy
sudo systemctl disable --now precise-hub-fetch

# Re-enable after fixing issues
sudo systemctl enable --now precise-hub-deploy
sudo systemctl enable --now precise-hub-fetch
```

## How It Works

### Deploy Pipeline (Uploads)

The deploy loop runs continuously (default: every 10 seconds) and scans for new archive files.

**Upload sources scanned:**
- `/mnt/deg/{ORG}/upload/` — all 7 organizations (DEG, external partners)
- `/mnt/forschungsspeicher/{ORG}/upload/` — UKF local imports (Forschungsspeicher)

The source is recorded in every log entry (`"source": "deg"` or `"source": "forschungsspeicher"`), so you can always trace where a package entered the data lake.

**Processing steps:**
1. Discover archive files matching `ORG_YYYY-MM-DD_NN.{tar.zst|tar.gz|zip}`
2. Validate via SHA-256 checksum (if `.sha256` file exists) or file stability check
3. Transfer archive to local hub staging area (`/var/tmp/precise-hub/deploy/`)
4. Extract locally, then rsync exam folders (`ORG_NNNNN`) to sharded location (`/mnt/data-lake/Data/{ORG}/{shard}/`). Each folder is written to a hidden `.partial_*` name first and renamed on completion, so an interrupted transfer never leaves a half-filled folder.
5. Delete the source archive from the DEG (only if every folder was stored or already existed; otherwise the archive is kept and retried next cycle)
6. Write an `upload` message to `[ORG]/messages/` and a JSON log to `/mnt/data-lake/logs/`

**Rejected uploads:** an archive with an invalid name, a corrupt archive, or one without `ORG_NNNNN` folders at the top level is renamed to `NAME.rejected` (checksum to `NAME.sha256.rejected`) and an error message is written. A finished upload whose checksum does not match gets its checksum file renamed to `NAME.sha256.mismatch`; the archive is kept and skipped until a new `.sha256` file arrives. A mismatch is only declared once the archive has been stable for `STABILITY_THRESHOLD` seconds, so a checksum uploaded before the archive is complete just waits.

### Fetch Pipeline (Requests)

The fetch loop runs continuously (default: every 30 seconds) and scans for new JSON request files.

**Request source scanned:**
- `/mnt/deg/{ORG}/requests/` — all 7 organizations

**Processing steps:**
1. Discover `.json` request files
2. Parse, validate (known org, valid ID format, IDs exist in data lake), write "received" message to `[ORG]/messages/`
3. Rsync exam folders from data lake to local hub staging (`/var/tmp/precise-hub/fetch/`), assemble archive + checksum
4. Transfer archive + checksum to `[ORG]/download/` on the DEG
5. Write "ready" message to `[ORG]/messages/`, archive request file to `[ORG]/archived-requests/`
6. Write JSON log to `/mnt/data-lake/logs/`

Failed requests (invalid JSON, unknown organization, no IDs found, transfer errors) are archived too, as `<timestamp>__FAILED__<request>.json`, after the error message has been written. A request is therefore never processed twice; to retry, the partner submits a new request file.

**Automatic cleanup:** Downloads older than `DOWNLOAD_EXPIRY_HOURS` are auto-deleted from `[ORG]/download/`.

### DEG Folder Layout (per Organization)

```
[ORG]/
├── upload/              # incoming data packages
├── requests/            # JSON fetch request files
├── archived-requests/   # processed request files
├── download/            # assembled fetch packages
└── messages/            # status notifications from the hub
```

### Data Lake Layout

```
/mnt/data-lake/
├── Data/
│   ├── UKF/
│   │   ├── 00000/          # exams UKF_00000 – UKF_00099
│   │   ├── 00100/          # exams UKF_00100 – UKF_00199
│   │   └── ...
│   ├── UKK/
│   └── ...
└── logs/                    # JSON processing logs
```

## Configuration

Edit `scripts/process/config.sh` to adjust processing parameters. The mount points, `LOCAL_STAGING_PATH` and the lock file paths can also be overridden through environment variables of the same name, which allows running the scripts against local test directories.

| Variable | Default | Description |
|----------|---------|-------------|
| `ORGANIZATIONS` | `UKK MUV UKF UHD MUI UKE FAU` | Organization codes to monitor |
| `UPLOAD_SOURCES` | `${DEG_PATH} ${FORSCHUNGSSPEICHER_PATH}` | Paths scanned for `{ORG}/upload/` folders |
| `DEPLOY_LOOP_INTERVAL` | `10` | Seconds between deploy processing cycles |
| `FETCH_LOOP_INTERVAL` | `30` | Seconds between fetch processing cycles |
| `STABILITY_THRESHOLD` | `60` | Seconds a file must be unchanged before processing (when no checksum) |
| `FETCH_MAX_SIZE` | `20G` | Maximum size of a single fetch download package |
| `DOWNLOAD_EXPIRY_HOURS` | `48` | Hours after which download packages are auto-deleted |
| `LOCAL_STAGING_PATH` | `/var/tmp/precise-hub` | Local hub directory for staging; `deploy/` and `fetch/` subdirectories, one per loop |
| `SHARD_SIZE` | `100` | Exam folders per shard directory |

After changing configuration, restart the affected service:
```bash
sudo systemctl restart precise-hub-deploy
sudo systemctl restart precise-hub-fetch
```

## Container Deployment (Alternative)

For container-based deployment using rootless Podman, see [docs/container-setup.md](docs/container-setup.md).