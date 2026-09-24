# PRECISE Hub — Upload Guide

Instructions for data providers uploading data packages to the PRECISE hub.

See also: [Fetch Guide](user-guide-fetch.md) — requesting data packages from the data lake.

## Upload Location

Place your data package in your organization's upload folder on the [Data Exchange Gateway](https://ukl-idim-hub.uniklinik-freiburg.de) (DEG):

```
ORG/upload/
```

## File Naming

```
ORG_YYYY-MM-DD_NN.EXTENSION
```

Example for UKF:
```
UKF/upload/UKF_2025-12-15_00.tar.zst
```

| Part | Meaning |
|------|---------|
| `ORG` | Your 3-letter organization code (e.g. `UKF`, `UKK`) |
| `YYYY-MM-DD` | Creation date (ISO 8601) |
| `NN` | Sequential number for that day, starting at `00` |
| Extension | `tar.zst` (preferred), `tar.gz`, or `zip` |

## Package Contents

Each archive must contain examination folders named `ORG_NNNNN` (5-digit number):

Example for UKF:
```
UKF_2025-12-15_00.tar.zst
├── UKF_00042/
│   └── (examination data)
├── UKF_00043/
│   └── (examination data)
└── ...
```

## Creating a Package

### Linux (CLI)

Create the archive from selected folders:
```bash
tar -cf - UKF_00042 UKF_00043 | zstd -o UKF_2025-12-15_00.tar.zst
```

Or archive all subfolders of a parent directory:
```bash
tar -cf - -C /path/to/parent . | zstd -o UKF_2025-12-15_00.tar.zst
```

Create the SHA-256 checksum file:
```bash
sha256sum UKF_2025-12-15_00.tar.zst > UKF_2025-12-15_00.tar.zst.sha256
```

Verify the checksum locally:
```bash
sha256sum -c UKF_2025-12-15_00.tar.zst.sha256
```

Upload both files to the DEG.

### Windows (7-Zip)

**Create the archive:**

1. Select the examination folders (e.g. `UKF_00042`, `UKF_00043`) — or select all subfolders inside a parent folder
2. Right-click → **7-Zip** → **Add to archive…**
3. Set **Archive format** to `tar`
4. Set the filename to `UKF_2025-12-15_00.tar` → **OK**
5. Right-click the `.tar` file → **7-Zip** → **Add to archive…**
6. Set **Archive format** to `zstd`
7. The result is `UKF_2025-12-15_00.tar.zst`

**Create the checksum:**

1. Right-click `UKF_2025-12-15_00.tar.zst` → **7-Zip** → **CRC SHA** → **SHA-256**
2. Copy the hash value shown by 7-Zip
3. Create a text file named `UKF_2025-12-15_00.tar.zst.sha256`
4. Paste the hash followed by two spaces and the filename:
   ```
   a1b2c3d4e5f6...  UKF_2025-12-15_00.tar.zst
   ```
5. Save as plain text (not Unicode/UTF-16)

Upload both files to the DEG.

## Checksum (Recommended)

A `.sha256` file alongside the archive enables immediate verification. Without it, the hub waits for the file to be stable (unchanged for 60 seconds) before processing.

The checksum file must contain the SHA-256 hash as the first field:
```
a1b2c3d4e5f6...  UKF_2025-12-15_00.tar.zst
```

Upload the archive first and the checksum file last: the checksum file tells the hub that the upload is complete.

## What Happens Next

The hub writes a status message to your `messages/` folder for every processed package (see the [Fetch Guide](user-guide-fetch.md#checking-status-messages) for the message format):

- `stored` — the package was processed. `stored_ids` lists the stored examinations, `skipped_existing_ids` those that were already in the data lake (existing examinations are never overwritten). The archive and its checksum file are removed from `upload/`.
- `rejected` — the package was not accepted. The `error` field explains why:
  - **Checksum mismatch:** the checksum file is renamed to `NAME.sha256.mismatch` and the archive is kept. Upload a correct `.sha256` file to retry, or re-upload both files.
  - **Invalid file name, corrupt archive, or no `ORG_NNNNN` folders at the top level:** the files are renamed to `NAME.rejected`. Fix the package and upload it again under its proper name.

Rejected files are deleted from `upload/` automatically after 48 hours.
