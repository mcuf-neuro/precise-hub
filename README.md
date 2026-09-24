# PRECISE Hub

Data management hub for the PRECISE consortium. Runs on a mainstream GNU/Linux system with systemd.

The hub connects three storage systems:
- **Data Exchange Gateway (DEG)** — WebDAV server in the DMZ where external partners upload and download data packages
- **Forschungsspeicher** — CIFS/AD research storage for UKF local data imports
- **Data Lake** — TrueNAS/CIFS long-term storage for all consortium data

Two independent processing loops run continuously:
- **Deploy** — scans for uploaded data packages, validates, extracts, and stores them in the data lake
- **Fetch** — scans for data fetch requests, assembles packages from the data lake, and delivers them to the DEG; also runs the DEG cleanup

Because the DEG (WebDAV) cannot reliably transfer files larger than a few GB, data moves as one package per examination (`ORG_NNNNN.tar.zst` + `.sha256`) in both directions.

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
├── space.sh               # shared disk space helpers
├── index.sh               # shared data index functions (update, publish)
├── deploy/
│   ├── run-deploy-loop.sh         # deploy processing loop
│   └── process-uploads.sh         # upload processing logic
├── fetch/
│   ├── run-fetch-loop.sh          # fetch processing loop
│   └── process-fetch-requests.sh  # fetch request processing logic
├── cleanup/
│   └── cleanup-deg.sh             # removes stale data from DEG upload/ and download/
└── index/
    └── rebuild-index.sh           # rebuilds the data index from the data lake content

scripts/test/e2e.sh        # end-to-end test against local fake mount directories
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

The end-to-end test runs both pipelines against temporary local directories and needs no mounts:
```bash
scripts/test/e2e.sh
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

**Index rebuild timer** (nightly, catches data injected directly into the data lake):
```bash
sudo tee /etc/systemd/system/precise-hub-index.service << 'EOF'
[Unit]
Description=PRECISE Hub Index Rebuild
After=remote-fs.target

[Service]
Type=oneshot
User=neuro
ExecStart=/opt/precise-hub/scripts/process/index/rebuild-index.sh
EOF

sudo tee /etc/systemd/system/precise-hub-index.timer << 'EOF'
[Unit]
Description=Nightly PRECISE Hub index rebuild

[Timer]
OnCalendar=*-*-* 00:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
```

Enable and start:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now precise-hub-deploy.service
sudo systemctl enable --now precise-hub-fetch.service
sudo systemctl enable --now precise-hub-index.timer
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
1. Discover archive files in `upload/` and one level of package folders (`upload/ORG_YYYY-MM-DD_NN/`). Two name patterns: `ORG_NNNNN.ext` (one examination, preferred) and `ORG_YYYY-MM-DD_NN.ext` (legacy batch). Extensions: `tar.zst`, `tar.gz`, `zip`.
2. Validate via SHA-256 checksum (if `.sha256` file exists) or file stability check. Each archive is handled on its own as soon as it is complete; the hub does not wait for a package folder to be "finished". Before the transfer, local staging must have `STAGING_SPACE_FACTOR` times the archive size free, otherwise the archive waits.
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
2. Parse, validate (known org, valid ID format, IDs exist in data lake)
3. Size checks from the data lake folder sizes, before anything is copied: cases above `FETCH_MAX_CASE_SIZE` are skipped (`too_large_ids`), a total above `FETCH_MAX_SIZE` is rejected, and the request is rejected if the DEG or the local staging area lacks the space. Then write "received" message to `[ORG]/messages/`
4. For each case: rsync from data lake to local staging (`/var/tmp/precise-hub/fetch/`), create `ORG_NNNNN.tar.zst` + `.sha256`, transfer both into `[ORG]/download/ORG_fetch_YYYY-MM-DD_NN/`. Finally write `manifest.json` there.
5. Write "ready" message to `[ORG]/messages/`, archive request file to `[ORG]/archived-requests/`
6. Write JSON log to `/mnt/data-lake/logs/`

Failed requests (invalid JSON, unknown organization, no IDs found, transfer errors) are archived too, as `<timestamp>__FAILED__<request>.json`, after the error message has been written. A request is therefore never processed twice; to retry, the partner submits a new request file.

### DEG Cleanup

`cleanup/cleanup-deg.sh` is called by the fetch loop every cycle and throttles itself to `CLEANUP_INTERVAL`. It removes files older than `UPLOAD_EXPIRY_HOURS` from `[ORG]/upload/` (rejected packages, checksum mismatches, abandoned uploads) and files older than `DOWNLOAD_EXPIRY_HOURS` from `[ORG]/download/`, then removes package folders that became empty and empty folders older than `EMPTY_FOLDER_EXPIRY_MINUTES`. Partners get an `expired` message per area.

Safety: the script refuses to run unless `DEG_PATH` is a mountpoint, only looks two levels below `upload/` and `download/` of the configured organizations, never follows symlinks and never touches `requests/`, `archived-requests/` or `messages/`.

```bash
# See what would be removed
/opt/precise-hub/scripts/process/cleanup/cleanup-deg.sh --dry-run
# Run now, ignoring the throttle
/opt/precise-hub/scripts/process/cleanup/cleanup-deg.sh --force
```

### Disk Space

The DEG free space is read with `df` on the davfs2 mount. davfs2 only reports real numbers if the WebDAV server supports quota properties. Check `df -h /mnt/deg` on the hub: if the number is obviously wrong, set `DEG_CAPACITY_BYTES` (e.g. `500G`) and the hub computes free space as capacity minus the size of all files in the upload and download folders.

Local staging (`LOCAL_STAGING_PATH`) needs room for roughly three copies of the largest package (davfs2 cache, archive copy, extracted content). Keep the davfs2 cache (`cache_dir` in `davfs2.conf`) on a local disk with enough space as well.

### Data Index

`/mnt/data-lake/index/index.json` lists every case in the data lake:

```json
{
  "generated": "2026-09-24T15:26:39Z",
  "case_count": 1234,
  "total_bytes": 987654321,
  "cases": [
    {"id": "UKF_00042", "org": "UKF", "shard": "00000", "size_bytes": 20480, "file_count": 12,
     "added_at": "2026-09-24T15:26:39Z", "updated_at": null, "source": "deg", "package": "UKF_00042.tar.zst"}
  ]
}
```

`size_bytes` is the uncompressed size as stored. The deploy loop adds entries after every stored package and publishes the index as `index.json` and `index.csv` into every `[ORG]/` folder on the DEG at the end of the cycle, so partners can look up which cases exist before writing fetch requests. The nightly `rebuild-index.sh` walks the data lake and picks up cases that were injected directly, keeping `added_at`, `source` and `package` of known cases (folder mtime and `unknown` for new ones). Run it by hand after a direct injection:

```bash
/opt/precise-hub/scripts/process/index/rebuild-index.sh
```

### DEG Folder Layout (per Organization)

```
[ORG]/
├── upload/              # incoming data packages (ORG_NNNNN.tar.zst + .sha256, optionally in a package folder)
├── requests/            # JSON fetch request files
├── archived-requests/   # processed request files (FAILED__ prefix for rejected ones)
├── download/            # one folder per fetch request with per-case packages and manifest.json
├── messages/            # status notifications from the hub
├── index.json           # data index (all cases in the data lake), published by the hub
└── index.csv            # same as CSV
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
├── index/
│   └── index.json           # data index (leading copy)
└── logs/                    # JSON processing logs
```

## Configuration

Edit `scripts/process/config.sh` to adjust processing parameters. The mount points, `LOCAL_STAGING_PATH`, the lock file paths and the size limits can also be overridden through environment variables of the same name, which allows running the scripts against local test directories.

| Variable | Default | Description |
|----------|---------|-------------|
| `ORGANIZATIONS` | `UKK MUV UKF UHD MUI UKE FAU` | Organization codes to monitor |
| `UPLOAD_SOURCES` | `${DEG_PATH} ${FORSCHUNGSSPEICHER_PATH}` | Paths scanned for `{ORG}/upload/` folders |
| `DEPLOY_LOOP_INTERVAL` | `10` | Seconds between deploy processing cycles |
| `FETCH_LOOP_INTERVAL` | `30` | Seconds between fetch processing cycles |
| `STABILITY_THRESHOLD` | `60` | Seconds a file must be unchanged before processing (when no checksum) or before a checksum mismatch / invalid name is declared |
| `FETCH_MAX_SIZE` | `20G` | Maximum total (uncompressed) size of one fetch request |
| `FETCH_MAX_CASE_SIZE` | `4G` | Maximum (uncompressed) size of one case; larger cases are skipped |
| `DEG_CAPACITY_BYTES` | empty | DEG capacity for the space check; empty trusts `df` on the DEG mount |
| `DEG_SPACE_MARGIN` | `1G` | Free space always kept on the DEG |
| `STAGING_SPACE_FACTOR` | `4` | Local staging must have this many times the archive size free before an upload is processed |
| `UPLOAD_EXPIRY_HOURS` | `48` | Hours after which files left in `upload/` are deleted |
| `DOWNLOAD_EXPIRY_HOURS` | `48` | Hours after which download packages are deleted |
| `EMPTY_FOLDER_EXPIRY_MINUTES` | `60` | Minutes after which empty package folders are removed |
| `CLEANUP_INTERVAL` | `600` | Seconds between DEG cleanup runs |
| `LOCAL_STAGING_PATH` | `/var/tmp/precise-hub` | Local hub directory for staging; `deploy/`, `fetch/` and `state/` subdirectories |
| `SHARD_SIZE` | `100` | Exam folders per shard directory |

After changing configuration, restart the affected service:
```bash
sudo systemctl restart precise-hub-deploy
sudo systemctl restart precise-hub-fetch
```

## Container Deployment (Alternative)

For container-based deployment using rootless Podman, see [docs/container-setup.md](docs/container-setup.md).