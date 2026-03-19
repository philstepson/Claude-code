# WorkDocs Lifecycle System

Automated folder organisation, SharePoint sync, and OCI Object Storage archiving
for Phil Stephenson (PWSTEPHE) — Oracle Principal Cloud Architect.

---

## Overview

This system manages a three-tier data lifecycle for work files on a MacBook:

```
~/WorkDocs (Hot)  →  SharePoint OneDrive (Warm)  →  OCI Object Storage (Cold/Archive)
  Active work          Weekly auto-sync               On-demand + lifecycle policy
```

Files are organised by a formal naming convention, synced to SharePoint weekly,
and archived to OCI when customers go dormant, content ages out, or SharePoint
approaches its quota limit.

---

## Folder Convention

### Naming rules
- No spaces anywhere — use hyphens as word separators
- Customer folders prefixed with `CO-`
- File names: descriptive kebab-case, version suffix where needed

### Top-level structure

```
~/WorkDocs/
│
├── CO-Calvert/                 ← Customer folders (CO- prefix)
│   ├── General/                   Default catch-all within each customer
│   └── Project-Name/              Named engagements in kebab-case
├── CO-FuelQuest/
├── CO-Kubota/
├── CO-Olympus/
│
├── Excel/                      ← Generic data-type folders
├── Images/
├── JSON/
├── PPT/
├── Python/
├── Shells/
├── SQL/
├── TXT/
└── Word/
│
└── General/                    ← Top-level catch-all (personal, unclassified)
```

### Rules
| File type | Destination |
|---|---|
| Customer-specific (any format) | `CO-CustomerName/` → project subfolder or `General/` |
| Generic non-customer file | Appropriate type folder (`SQL/`, `Excel/`, etc.) |
| Personal / unclassified / temp | `General/` |
| Customer-specific files | **Never** in a data-type folder |

---

## Prerequisites

| Tool | Purpose | Install |
|---|---|---|
| Microsoft OneDrive app | SharePoint sync via local mount | Mac App Store |
| OCI CLI | Archive and lifecycle management | `brew install oci-cli` |
| rsync | File sync (pre-installed on macOS) | — |

### OCI configuration (philip.stephenson)
| Parameter | Value |
|---|---|
| Namespace | `axxduehrw7lz` |
| Region | `us-phoenix-1` |
| Compartment | `philip.stephenson` |
| Compartment OCID | `ocid1.compartment.oc1..aaaaaaaa4gxfntpkf65wzzoddjuak6fk4emk6fj2t2pmf6bpglotjjhk436a` |
| Archive bucket | `workdocs-archive` |

### SharePoint configuration
| Parameter | Value |
|---|---|
| OneDrive mount | `~/Library/CloudStorage/OneDrive-OracleCorporation/` |
| WorkDocs path on SharePoint | `~/Library/CloudStorage/OneDrive-OracleCorporation/WorkDocs/` |
| Quota | 1024 GB (1 TB) |
| Portal | https://oracle-my.sharepoint.com/my |

---

## Scripts

### 01-create-workdocs-structure.sh
Creates the full WorkDocs folder hierarchy locally.

```bash
./01-create-workdocs-structure.sh              # creates ~/WorkDocs
./01-create-workdocs-structure.sh /custom/path # custom location
```

Run once during initial setup. Safe to re-run — only adds missing folders.

---

### 02-migrate-to-sharepoint.sh
Rsyncs `~/WorkDocs` to the SharePoint OneDrive mount. The OneDrive client
handles upload to SharePoint in the background.

```bash
./02-migrate-to-sharepoint.sh                  # dry run
./02-migrate-to-sharepoint.sh --go             # live copy
./02-migrate-to-sharepoint.sh --go --delete-local  # copy + remove ~/WorkDocs after verify
```

- Excludes `.DS_Store`, `._*`, `.Spotlight-V100`, `.Trashes`
- Uses additive rsync — never removes files from SharePoint
- `--delete-local` verifies file counts before removing local copy

---

### 03-archive-to-oci.sh
Archives WorkDocs content from SharePoint to OCI Object Storage.

**Archive a dormant customer:**
```bash
./03-archive-to-oci.sh --customer CO-Calvert           # dry run
./03-archive-to-oci.sh --customer CO-Calvert --go      # live
```
Compresses entire `CO-*` folder to `.tar.gz`, uploads at **InfrequentAccess** tier
(fast restore if the customer re-engages), then removes from SharePoint.

**Age out old data-type content:**
```bash
./03-archive-to-oci.sh --age-out 180                   # dry run (180 days)
./03-archive-to-oci.sh --age-out 180 --go              # live
```
Archives files in `PPT/`, `Excel/`, `Word/`, `TXT/`, `JSON/`, `SQL/`, `Shells/`,
`Python/`, `Images/` not modified in the last N days. Uploads at **Archive** tier
(lowest cost, cold storage).

**List archived objects:**
```bash
./03-archive-to-oci.sh --list
```

OCI object naming:
- Customer archives: `customers/CO-Calvert-archived-2026-03.tar.gz`
- Age-out archives: `datatypes/PPT-aged-out-2026-03.tar.gz`
- Emergency archives: `emergency/WorkDocs-full-backup-20260319-114747.tar.gz`

---

### 04-set-lifecycle-policy.sh
Applies an OCI Object Storage lifecycle policy to `workdocs-archive`.
Runs server-side automatically — no local process required after setup.

```bash
./04-set-lifecycle-policy.sh                   # preview policy
./04-set-lifecycle-policy.sh --apply           # apply to bucket
./04-set-lifecycle-policy.sh --show            # read back current policy
./04-set-lifecycle-policy.sh --delete          # remove policy
```

**Lifecycle transitions:**

| Prefix | Day 0 | Day 90 | Day 2555 (7 years) |
|---|---|---|---|
| `customers/` | InfrequentAccess | → Archive | → DELETED |
| `datatypes/` | Archive | — | → DELETED |

Adjust `CUSTOMER_TO_ARCHIVE_DAYS` and `RETENTION_DAYS` at the top of the script
to match Oracle's data retention policy requirements.

---

### 05-weekly-sync-and-monitor.sh
Runs automatically every Sunday at midnight via launchd. Can also be triggered manually.

```bash
./05-weekly-sync-and-monitor.sh                # dry run
./05-weekly-sync-and-monitor.sh --go           # live
launchctl start com.oracle.workdocs-weeklysync # trigger launchd job now
```

**What it does on each run:**
1. rsync `~/WorkDocs` → SharePoint
2. Check SharePoint storage usage as % of 1 TB quota
3. If usage ≥ 90%: compress full WorkDocs → upload to OCI `emergency/` → clear SharePoint
4. Send macOS notification with quota %

**Logs:** `~/Library/Logs/workdocs-weekly-<timestamp>.log`

---

### install-launchd.sh
Installs and activates the weekly launchd agent. Run once.

```bash
./install-launchd.sh           # install
./install-launchd.sh --remove  # uninstall
```

**launchd management:**
```bash
launchctl list | grep workdocs          # check status
launchctl start com.oracle.workdocs-weeklysync  # run now
launchctl unload ~/Library/LaunchAgents/com.oracle.workdocs-weeklysync.plist
```

---

## Lifecycle Pipeline

```
                    ┌─────────────────────────────────────────────────┐
                    │              OCI Object Storage                 │
                    │           workdocs-archive bucket               │
                    │                                                 │
  customers/        │  InfrequentAccess ──day 90──▶ Archive           │
  datatypes/        │  Archive                                        │
  emergency/        │  (any tier) ────day 2555──▶ DELETED             │
                    └─────────────────────────────────────────────────┘
                              ▲                  ▲
                   script 03  │       script 05  │ (at 90% quota)
                   on-demand  │       automatic  │
                              │                  │
                    ┌─────────────────────────────────────────────────┐
                    │             SharePoint OneDrive                 │
                    │    oracle-my.sharepoint.com/my  (1 TB)          │
                    │                                                 │
                    │    WorkDocs/CO-*/  WorkDocs/Excel/  etc.        │
                    └─────────────────────────────────────────────────┘
                              ▲
                   script 02  │ (initial)
                   script 05  │ (weekly, Sunday midnight)
                              │
                    ┌─────────────────────────────────────────────────┐
                    │           ~/WorkDocs (local Mac)                │
                    │                                                 │
                    │    Active customers, current content            │
                    └─────────────────────────────────────────────────┘
```

---

## Initial Setup (completed)

- [x] Folder structure created (`01`)
- [x] Downloads migrated to SharePoint (`02`)
- [x] OCI archive bucket created (`workdocs-archive`)
- [x] OCI lifecycle policy applied (`04`)
- [x] launchd weekly agent installed (`install-launchd.sh`)

---

## Adding a New Customer

```bash
mkdir -p ~/WorkDocs/CO-NewCustomer/General
# Optionally create a project subfolder
mkdir -p ~/WorkDocs/CO-NewCustomer/Project-Name
```

The next weekly sync (or a manual `./02-migrate-to-sharepoint.sh --go`) will
push the new folder to SharePoint.

## Archiving a Dormant Customer

```bash
./03-archive-to-oci.sh --customer CO-Calvert --go
```

## Restoring from OCI Archive

Objects in **InfrequentAccess** tier download immediately:
```bash
oci os object get \
  --namespace axxduehrw7lz \
  --bucket-name workdocs-archive \
  --region us-phoenix-1 \
  --name customers/CO-Calvert-archived-2026-03.tar.gz \
  --file ~/WorkDocs/CO-Calvert-restored.tar.gz
```

Objects in **Archive** tier must be restored first (up to 1 hour):
```bash
oci os object restore \
  --namespace axxduehrw7lz \
  --bucket-name workdocs-archive \
  --region us-phoenix-1 \
  --object-name customers/CO-Calvert-archived-2026-03.tar.gz
# Wait for restore, then use the get command above
```
