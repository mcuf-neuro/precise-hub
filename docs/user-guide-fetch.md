# PRECISE Hub — Fetch Guide

Instructions for requesting data packages from the PRECISE data lake.

See also: [Upload Guide](user-guide-upload.md) — uploading data packages to the hub.

## Overview

To request examination data from other sites, you deposit a JSON request file on the [Data Exchange Gateway](https://ukl-idim-hub.uniklinik-freiburg.de) (DEG). The hub assembles the requested data into a download package and notifies you when it's ready.

## Your DEG Folder Layout

```
[ORG]/
├── upload/              # upload data packages here
├── requests/            # place fetch request files here
├── archived-requests/   # your processed requests (for reference)
├── download/            # the hub places assembled packages here
└── messages/            # status notifications from the hub
```

## Creating a Fetch Request

Create a JSON file with the examination IDs you need. Place it in your organization's `requests/` folder on the DEG.

**Filename format:** `request_YYYY-MM-DD_NN.json`

```json
{
  "organization": "UKF",
  "requested_ids": [
    "UKK_00301",
    "UKW_02043"
  ],
  "comment": "Needed for cross-site analysis batch 7"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `organization` | string | yes | Your 3-letter organization code |
| `requested_ids` | string[] | yes | List of examination folder IDs (e.g. `UKK_00301`) |
| `comment` | string | no | Free-text reason / context for the request |

### Example

UKF requests two examinations from other sites:

1. Create file `request_2026-04-16_00.json` with the content above
2. Upload it to `UKF/requests/` on the DEG

## What Happens Next

1. **Acknowledgment** — The hub writes a "received" message to your `messages/` folder confirming it has seen the request.

2. **Validation** — The hub checks that the requested IDs exist in the data lake. If any ID is invalid or not found, you'll get an error message in `messages/` explaining why.

3. **Assembly** — The hub packs every requested examination into its own archive (`ORG_NNNNN.tar.zst`, containing the folder `ORG_NNNNN/`) with a checksum file. Per-examination packages keep every transfer below the DEG size limit.

4. **Delivery** — A folder named after your request appears in `download/`:
   ```
   UKF/download/
   └── UKF_fetch_2026-04-16_00/
       ├── manifest.json               # list of cases, sizes and checksums
       ├── UKK_00301.tar.zst
       ├── UKK_00301.tar.zst.sha256
       ├── UKW_02043.tar.zst
       └── UKW_02043.tar.zst.sha256
   ```

5. **Notification** — A "ready" message in your `messages/` folder names the download folder and lists `included_ids`, `skipped_ids` (not in the data lake) and `too_large_ids` (above the per-case limit).

6. **Archival** — Your original request file is moved from `requests/` to `archived-requests/` so you can reference it later.

## Downloading the Package

Connect to the DEG with WinSCP or another client and download the whole folder `[ORG]/download/UKF_fetch_2026-04-16_00/`.

### Verify the Checksums

**Linux:**
```bash
cd UKF_fetch_2026-04-16_00 && sha256sum -c *.sha256
```

**Windows (7-Zip):**
1. Right-click a `.tar.zst` file → **7-Zip** → **CRC SHA** → **SHA-256**
2. Compare the displayed hash with the content of the matching `.sha256` file

### Extract the Archives

**Linux:**
```bash
for f in *.tar.zst; do tar -xf "$f" --use-compress-program=zstd; done
```

**Windows (7-Zip):**
1. Select all `.tar.zst` files → right-click → **7-Zip** → **Extract Here**
2. Select the resulting `.tar` files → right-click → **7-Zip** → **Extract Here**

Each archive extracts to one examination folder, e.g. `UKK_00301/`.

## Checking Status Messages

The hub writes JSON messages to your `messages/` folder. Check this folder for updates:

| Message `status` | Meaning |
|-------------------|---------|
| `received` | Hub has received and is processing your request |
| `ready` | Package is assembled and available in `download/` |
| `error` | Something went wrong — see the `error` field for details |
| `expired` | Download packages were auto-deleted (default: after 48 hours) |

Upload results are reported in the same folder with `type: "upload"`:

| Message `status` | Meaning |
|-------------------|---------|
| `stored` | Package processed; `stored_ids` lists the stored examinations, `skipped_existing_ids` those that already existed |
| `rejected` | Package not accepted — see the `error` field (invalid name, corrupt archive, checksum mismatch, no examination folders) |

## Important Notes

- **Download expiry:** Packages in `download/` are automatically deleted after 48 hours. Download promptly after receiving a "ready" notification.
- **Failed requests:** A request that could not be fulfilled is moved to `archived-requests/` with a `FAILED` marker in its name, together with an error message in `messages/`. To retry, submit a new request file.
- **Size limits:** A single examination larger than 4 GB cannot be transferred through the DEG and is skipped (listed in `too_large_ids`). A request whose examinations exceed 20 GB in total is rejected; split it into several requests. If the DEG is out of space, the request is rejected with an error message; download and delete your existing packages, then resubmit.
- **One request per file:** Each JSON file should contain one request. For multiple independent requests, create separate files (`request_2026-04-16_00.json`, `request_2026-04-16_01.json`, …).
- **Examination IDs:** IDs follow the format `ORG_NNNNN` (3-letter org code + underscore + 5-digit number). You need to know the exact IDs you want to request.
