# PRECISE Hub — Upload Guide

Instructions for data providers uploading data packages to the PRECISE hub.

See also: [Fetch Guide](user-guide-fetch.md) — requesting data packages from the data lake.

## Upload Location

Place your data packages in your organization's upload folder on the [Data Exchange Gateway](https://ukl-idim-hub.uniklinik-freiburg.de) (DEG):

```
ORG/upload/
```

## Package Format: One Package per Examination

The DEG (WebDAV) cannot reliably transfer files larger than a few gigabytes. Therefore every examination is uploaded as its own package: an archive `ORG_NNNNN.tar.zst` containing the examination folder `ORG_NNNNN/`, plus a checksum file `ORG_NNNNN.tar.zst.sha256`.

Group the packages of one upload in a folder named `ORG_YYYY-MM-DD_NN` and upload the whole folder:

```
UKF/upload/
└── UKF_2025-12-15_00/
    ├── UKF_00042.tar.zst           # contains UKF_00042/ with the examination data
    ├── UKF_00042.tar.zst.sha256
    ├── UKF_00043.tar.zst           # contains UKF_00043/
    ├── UKF_00043.tar.zst.sha256
    └── ...
```

| Part | Meaning |
|------|---------|
| `ORG` | Your 3-letter organization code (e.g. `UKF`, `UKK`) |
| `NNNNN` | 5-digit examination number, e.g. `UKF_00042` |
| `YYYY-MM-DD` | Creation date of the upload folder (ISO 8601) |
| `NN` | Sequential number for that day, starting at `00` |
| Extension | `tar.zst` (preferred), `tar.gz`, or `zip` |

Rules:

- Each archive contains exactly one folder, `ORG_NNNNN/`, at its top level. The archive is named after that folder.
- Every archive must have a checksum file next to it; archives without one are not processed. Upload the archive first, then its checksum file: the checksum file tells the hub that the archive is complete. Most clients (e.g. WinSCP) upload a folder in alphabetical order, which already does this.
- Package files may also be placed directly in `upload/` without a grouping folder.
- Packages are processed one by one, as soon as each one is complete. A problem with one examination does not affect the others.

## Creating the Packages

### Linux (CLI)

From the directory that contains the examination folders:

```bash
mkdir UKF_2025-12-15_00
for exam in UKF_00042 UKF_00043; do
  tar -cf - "$exam" | zstd -o "UKF_2025-12-15_00/$exam.tar.zst"
done
cd UKF_2025-12-15_00
for f in *.tar.zst; do sha256sum "$f" > "$f.sha256"; done
```

Verify the checksums locally:
```bash
sha256sum -c *.sha256
```

Upload the folder `UKF_2025-12-15_00` to `UKF/upload/` on the DEG.

### Windows (7-Zip)

Repeat for each examination folder (e.g. `UKF_00042`):

**Create the archive:**

1. Right-click the folder `UKF_00042` → **7-Zip** → **Add to archive…**
2. Set **Archive format** to `tar`, filename `UKF_00042.tar` → **OK**
3. Right-click `UKF_00042.tar` → **7-Zip** → **Add to archive…**
4. Set **Archive format** to `zstd` → **OK**. The result is `UKF_00042.tar.zst`; delete the intermediate `.tar`.

**Create the checksum:**

1. Right-click `UKF_00042.tar.zst` → **7-Zip** → **CRC SHA** → **SHA-256**
2. Copy the hash value shown by 7-Zip
3. Create a text file named `UKF_00042.tar.zst.sha256`
4. Paste the hash followed by two spaces and the filename:
   ```
   a1b2c3d4e5f6...  UKF_00042.tar.zst
   ```
5. Save as plain text (not Unicode/UTF-16)

Collect all `.tar.zst` and `.sha256` files in a folder `UKF_2025-12-15_00` and upload that folder with WinSCP to `UKF/upload/`.

## Batch Packages (Legacy)

A single archive `ORG_YYYY-MM-DD_NN.tar.zst` containing several examination folders is still accepted, but only if it is smaller than the DEG transfer limit (a few GB). Prefer per-examination packages.

## Checksum (Required)

The checksum file must contain the SHA-256 hash as the first field:
```
a1b2c3d4e5f6...  UKF_00042.tar.zst
```

The hub processes an archive only after a matching checksum file has arrived. An archive that has no checksum file after one hour is rejected; upload both files again.

## What Happens Next

The hub writes a status message to your `messages/` folder for every processed package (see the [Fetch Guide](user-guide-fetch.md#checking-status-messages) for the message format):

- `stored` — the package was processed. `stored_ids` lists the stored examinations, `skipped_existing_ids` those that were already in the data lake (existing examinations are never overwritten). The archive and its checksum file are removed from `upload/`.
- `rejected` — the package was not accepted. The `error` field explains why:
  - **Checksum mismatch:** the checksum file is renamed to `NAME.sha256.mismatch` and the archive is kept. Upload a correct `.sha256` file to retry, or re-upload both files.
  - **Missing checksum file (after one hour), invalid file name, corrupt archive, or no `ORG_NNNNN` folder at the top level:** the files are renamed to `NAME.rejected`. Fix the package and upload it again under its proper name.

Files left in `upload/` (rejected packages, abandoned uploads) are deleted automatically after 48 hours. Empty upload folders are removed after one hour.
