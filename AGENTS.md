# AGENTS.md — WorkDocs Lifecycle System

This file provides context for Claude or any AI agent working in this directory.
Read this before making any changes to scripts or configuration.

---

## What this project is

A set of shell scripts that manage a three-tier data lifecycle for work files
belonging to Phil Stephenson (PWSTEPHE), Principal Cloud Architect at Oracle.

The three tiers are:
1. **Hot** — `~/WorkDocs/` on the local Mac (active work)
2. **Warm** — SharePoint OneDrive at oracle-my.sharepoint.com/my (synced, accessible)
3. **Cold** — OCI Object Storage bucket `workdocs-archive` in the `philip.stephenson`
   compartment, region `us-phoenix-1` (compressed archives, auto-tiered by lifecycle policy)

---

## Scripts in this directory

| File | Purpose |
|---|---|
| `01-create-workdocs-structure.sh` | Creates local WorkDocs folder hierarchy |
| `02-migrate-to-sharepoint.sh` | rsync ~/WorkDocs → SharePoint OneDrive mount |
| `03-archive-to-oci.sh` | On-demand archive of customers or aged files to OCI |
| `04-set-lifecycle-policy.sh` | Applies OCI auto-tiering lifecycle policy to the bucket |
| `05-weekly-sync-and-monitor.sh` | Weekly automated sync + SharePoint quota monitoring |
| `install-launchd.sh` | Installs launchd agent for weekly midnight automation |
| `com.oracle.workdocs-weeklysync.plist` | macOS launchd plist (Sunday midnight schedule) |

The launchd agent is already installed and active. `05-weekly-sync-and-monitor.sh`
runs every Sunday at midnight via `~/Library/LaunchAgents/com.oracle.workdocs-weeklysync.plist`.

---

## Hardcoded values — do not change without updating all scripts

| Value | Setting |
|---|---|
| OCI namespace | `axxduehrw7lz` |
| OCI region | `us-phoenix-1` |
| OCI compartment OCID | `ocid1.compartment.oc1..aaaaaaaa4gxfntpkf65wzzoddjuak6fk4emk6fj2t2pmf6bpglotjjhk436a` |
| OCI bucket | `workdocs-archive` |
| OneDrive mount | `~/Library/CloudStorage/OneDrive-OracleCorporation/` |
| SharePoint quota | 1024 GB |
| Emergency archive threshold | 90% of quota |
| Customer → Archive transition | 90 days after upload |
| Retention / auto-delete | 2555 days (7 years) after upload |

---

## Naming convention (enforced across all scripts)

- **No spaces** in any folder or file name — use hyphens
- **Customer folders**: `CO-CustomerName` (e.g. `CO-Calvert`, `CO-Kubota`)
- **Project subfolders**: kebab-case (e.g. `Cloud-Assessment`, `ERP-Migration`)
- **Data-type folders**: `Excel`, `Word`, `PPT`, `Images`, `JSON`, `Python`, `Shells`, `SQL`, `TXT`
- **General catch-all**: `General/` (top-level and inside each customer folder)
- **OCI object prefixes**: `customers/`, `datatypes/`, `emergency/`

Customer-specific files must never be placed in data-type folders.
Data-type folders must never contain customer-specific content.

---

## Key design decisions

**rsync is additive only** — script 02 never deletes files from SharePoint based on
local state. Files removed locally remain on SharePoint until explicitly archived (script 03)
or until the OCI lifecycle policy deletes them.

**SharePoint is accessed via the local OneDrive mount** — not via rclone or OAuth.
The Microsoft OneDrive app is already running and authenticated to the Oracle M365 tenant.
The mount is at `~/Library/CloudStorage/OneDrive-OracleCorporation/`.
Do not introduce rclone or Graph API auth — it conflicts with Oracle corporate SSO.

**OCI authentication uses the existing CLI config** — `~/.oci/config` is already
configured for the `philip.stephenson` compartment. Do not add profile flags or
re-configure auth in scripts.

**Storage tiers are intentional:**
- Customer archives → `InfrequentAccess` (quick restore if a dormant customer re-engages)
- Data-type age-outs → `Archive` (cold, cheapest, restore takes up to 1 hour)
- Emergency full-backup → `Standard` (may need immediate restore after quota evacuation)

**Checksum verification is mandatory** — all OCI uploads use `--verify-checksum`.
Source files are never deleted until the upload is confirmed.

**macOS launchd, not cron** — the weekly schedule uses launchd so that if the Mac
was asleep at midnight, the job runs on next wake. Do not migrate to cron.

---

## What currently exists in OCI

The `workdocs-archive` bucket exists in `philip.stephenson` / `us-phoenix-1`.
The lifecycle policy has been applied (see `04-set-lifecycle-policy.sh --show` to verify).
No customer archives have been uploaded yet — the bucket was created as part of setup.

---

## Common tasks for an agent

**Add a new customer:**
```bash
mkdir -p ~/WorkDocs/CO-NewCustomer/General
```
The next Sunday sync will push it to SharePoint automatically.

**Archive a dormant customer:**
```bash
./03-archive-to-oci.sh --customer CO-CustomerName --go
```

**Check what's archived:**
```bash
./03-archive-to-oci.sh --list
```

**Run the weekly sync manually:**
```bash
./05-weekly-sync-and-monitor.sh --go
```

**Check launchd agent status:**
```bash
launchctl list | grep workdocs
```

---

## Files that must not be modified without care

- `com.oracle.workdocs-weeklysync.plist` — changing the script path requires
  reinstalling via `install-launchd.sh`
- Any hardcoded OCID — these are production Oracle tenancy identifiers
- The `--verify-checksum` flag in any OCI upload — removing it breaks the
  safety guarantee that source files are only deleted after confirmed upload

---

## See also

`README.md` in this directory — full user-facing documentation including
setup steps, script reference, pipeline diagram, and restore instructions.
