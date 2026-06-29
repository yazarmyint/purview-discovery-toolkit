# Microsoft Purview Discovery & Migration Toolkit

A set of **read-only** PowerShell scripts for inventorying a Microsoft Purview
configuration, comparing two tenants, and generating self-contained HTML reports.
Built for Microsoft 365 tenant-to-tenant migrations and point-in-time Purview
baselines, but equally usable for an internal admin assessing their own tenant.

The scripts only ever issue `Get-*` / `Export-*` / `Search-*` cmdlets — they never
modify tenant state.

---

## ⚠️ This toolkit generates sensitive data — read before running

Two of the scripts return **item-level metadata**, not just counts:

- **Content Explorer inventory (`-Detailed` mode)** returns file names, document URLs,
  site URLs, and user principal names for every matching item.
- **Audit-log export** returns per-event detail including object IDs (file/message
  identifiers), user IDs, and policy/SIT match details.

On a regulated tenant (healthcare, finance, government), this metadata can itself be
sensitive — a file path or mailbox UPN is identifying even without the file contents.

**Treat all output folders as confidential.** Keep them inside whatever sanctioned
environment your engagement or organization requires, and delete them when the
assessment is complete. The reports are marked with a classification banner for this
reason; the raw CSV/JSON exports are not — handle them accordingly.

---

## What it does

Five scripts. A and B/C collect; D compares; E reports.

| # | Script | Purpose | Connects to |
|---|--------|---------|-------------|
| A | `Invoke-PurviewSourceDiscovery.ps1` | Export the full Purview config (Information Protection, classification, DLP, data lifecycle/records, audit) of a tenant to JSON + CLIXML + CSV with a manifest | Security & Compliance PowerShell + Exchange Online |
| B | `Export-PurviewContentInventory.ps1` | Content Explorer item counts (and optional item-level detail) per SIT / sensitivity label / retention label | Security & Compliance PowerShell |
| C | `Export-PurviewAuditSample.ps1` | Sample unified-audit-log export for DLP / labeling / disposition activity over a date window | Exchange Online |
| D | `Compare-SourceToTarget.ps1` | Diff two discovery runs (source vs. rebuilt target) into a migration mapping workbook + HTML report | None (local) |
| E | `New-PurviewReport.ps1` | Client-ready, offline HTML report (baseline or comparison) from the toolkit output | None (local) |

---

## Prerequisites

- **PowerShell 5.1+** (Windows recommended for full Security & Compliance PowerShell support)
- **ExchangeOnlineManagement** module (`Install-Module ExchangeOnlineManagement`)
- Connectivity to Security & Compliance PowerShell and/or Exchange Online
- Appropriate read permissions — **see the table below, the Content Explorer row in
  particular**

### Permissions

| Script | Minimum access |
|--------|----------------|
| A | An account with read access to Purview configuration (e.g., Compliance Administrator, or a custom view-only role group) |
| B | **Content Explorer List Viewer** (aggregate counts) or **Content Explorer Content Viewer** (item-level detail). **These roles are *not* part of the Compliance Administrator role group** — they must be assigned explicitly |
| C | A role permitting `Search-UnifiedAuditLog` (e.g., Audit Logs / View-Only Audit Logs). Unified audit logging must be enabled in the tenant |
| D, E | None — they run against local files |

> The Content Explorer requirement trips people up: Compliance Administrator looks
> sufficient but isn't. If Script B returns access errors, that's almost always the cause.

---

## Workflow

```
1.  A  →  run against the SOURCE tenant            → SourceDiscovery-<timestamp>/
2.  B, C  (optional) →  run against the SOURCE     → content inventory + audit sample
3.  A  →  run against the TARGET tenant after the rebuild
4.  D  →  diff the two A-run folders               → Comparison-<timestamp>/
5.  E  →  report:
          • Baseline   : point at an A-run folder
          • Comparison : point at a D-run folder
```

For a one-tenant baseline (no migration), run A then E in Baseline mode and stop there.

---

## Configuring it for your own use

The collection scripts take a `-SourceUpn` and write under `-OutputRoot`
(default `C:\PurviewDiscovery`). Adjust the record types, date window, and page sizes
via their parameters.

The **report** script (E) carries the labeling you'll want to change:

| Parameter | Default | Set this to |
|-----------|---------|-------------|
| `-OrganizationName` | `Your Organization` | The org/tenant being assessed |
| `-PreparedBy` | `Your Organization` | Whoever produced the report |
| `-ReportTitle` | `Microsoft Purview Configuration Report` | Your preferred report title |
| `-Classification` | `Confidential` | Your required handling marking |
| `-TenantLabel` | *(empty)* | Optional tenant identifier shown in the header |
| `-LogoPath` | *(none)* | Optional path to a logo image, embedded inline |

Example:

```powershell
.\New-PurviewReport.ps1 -ReportType Baseline `
    -Path C:\PurviewDiscovery\SourceDiscovery-20260628-101500 `
    -OrganizationName "Your Org" -PreparedBy "Your Org" -Classification "Internal"
```

---

## Reporting — suggested actions

The comparison report tags each control with a status and a **suggested action**. These
are heuristics from a configuration diff, not decisions — final calls require an owner's
sign-off.

| Status | Suggested action |
|--------|------------------|
| Match | Carry forward — verify, then decommission at source |
| Changed | Review delta — confirm intended vs. configuration drift |
| Only in source | Retire or recreate — decide carry-forward |
| Only in target | Confirm net-new — validate it was intended |

**Consolidation cannot be auto-detected.** If two source controls were merged into one
target control, the diff sees the second as "only in source." Review "only in source"
clusters manually for overlap.

---

## Limitations & caveats

- **Not a compliance attestation.** This reflects configuration observed at a point in
  time, to support migration planning and rationalization.
- **The audit export is a sample.** Unified-audit `ReturnLargeSet` is capped at ~50,000
  records per session and returns unsorted; the script segments by day to stay under the
  cap, but for complete, durable evidence forward the audit log to a SIEM or use the
  Purview Audit Search Graph API.
- **`Match` in the comparison is a *structural* match, not a behavioral one.** It means a
  control with the same key and matching top-level properties exists in both tenants — not
  that the two are functionally equivalent. Validate detection logic separately.
- **Some artifacts don't migrate one-for-one.** Custom trainable classifiers and EDM
  schemas have to be rebuilt and re-validated in the target; document them manually.
- **Audit record types:** endpoint-DLP and disposition activity are captured under the
  `DLPEndpoint` and `MultiStageDisposition` record types respectively (not
  `ComplianceDLPEndpoint` / `Disposition`, which are not valid enum members).

---

## For consultants

The defaults are tenant-neutral so the tool reads naturally for internal self-assessment.
If you're using it on a client engagement: set `-OrganizationName` to the client,
`-PreparedBy` to your firm, and `-Classification` to the client's required marking. Keep
all output inside your engagement's approved data-handling boundary.

---

## Disclaimer

Not affiliated with, endorsed by, or sponsored by Microsoft. "Microsoft Purview,"
"Content Explorer," and related names are trademarks of Microsoft. These scripts call
public, documented PowerShell cmdlets; cmdlet behavior is subject to change by Microsoft.
Provided as-is, with no warranty. **You are responsible for the data these scripts
generate and for running them only against tenants you are authorized to assess.**

## License

Released under the [MIT License](LICENSE.md) © 2026 Yazar Myint.
