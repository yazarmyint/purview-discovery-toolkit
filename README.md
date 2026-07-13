# Microsoft Purview Discovery Toolkit

A set of **read-only** PowerShell scripts for inventorying a Microsoft Purview
configuration and generating self-contained HTML reports. Built for point-in-time
Purview baselines and internal assessment of your own tenant.

The scripts only ever issue `Get-*` / `Export-*` / `Search-*` cmdlets — they never
modify tenant state.

---

## ⚠️ This toolkit generates sensitive data — read before running

Some collection modes return **item-level metadata**, not just counts:

- **Content Explorer inventory (`-Detailed` mode)** returns file names, document URLs,
  site URLs, and user principal names for every matching item.
- **Audit-log export** returns per-event detail including object IDs (file/message
  identifiers), user IDs, and policy/SIT match details.
- **Mailbox hold sweep (`-IncludeMailboxHolds -MailboxDetail`)** returns one row per
  mailbox including user principal names. Without `-MailboxDetail`, the sweep records
  aggregate counts only (no UPNs); without `-IncludeMailboxHolds` it does not run at all.

On a regulated tenant (healthcare, finance, government), this metadata can itself be
sensitive — a file path or mailbox UPN is identifying even without the file contents.

**Treat all output folders as confidential.** Keep them inside whatever sanctioned
environment your engagement or organization requires, and delete them when the
assessment is complete. The reports are marked with a classification banner for this
reason; the raw CSV/JSON exports are not — handle them accordingly.

---

## What it does

Four scripts. A collects the configuration; B and C collect content and audit detail; E reports.

| # | Script | Purpose | Connects to |
|---|--------|---------|-------------|
| A | `Invoke-PurviewSourceDiscovery.ps1` | Snapshot the full Purview config (Information Protection, classification, DLP, data lifecycle/records, audit) of a tenant into one schema-versioned `snapshot.json` (plus XML/ZIP sidecars and a `_manifest.csv` status view) — see `docs/SNAPSHOT-SCHEMA.md` | Security & Compliance PowerShell + Exchange Online |
| B | `Export-PurviewContentInventory.ps1` | Content Explorer item counts (and optional item-level detail) per SIT / sensitivity label / retention label | Security & Compliance PowerShell |
| C | `Export-PurviewAuditSample.ps1` | Sample unified-audit-log export for DLP / labeling / disposition activity over a date window | Exchange Online |
| E | `New-PurviewReport.ps1` | Client-ready, offline HTML report (discovery baseline) from the toolkit output | None (local) |

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
| E | None — runs against local files |

> The Content Explorer requirement trips people up: Compliance Administrator looks
> sufficient but isn't. If Script B returns access errors, that's almost always the cause.

---

## Workflow

```
1.  A  →  run against the tenant                    → PurviewSnapshot-<timestamp>/
2.  B, C  (optional) →  run against the tenant      → content inventory + audit sample
3.  E  →  point at the A-run folder                 → HTML discovery baseline report
```

For a minimal baseline, run A then E and stop there; B and C add content-level and
audit detail when you need them.

---

## Configuring it for your own use

The collection scripts take a `-UserPrincipalName` and write under `-OutputRoot`
(default `C:\PurviewDiscovery`). Adjust the record types, date window, and page sizes
via their parameters. Script A also accepts an optional `-SnapshotLabel` (e.g.
`Baseline`, `Closeout`) that is stamped into the snapshot's provenance — useful when
you will later compare a start-of-engagement snapshot with an end-of-engagement one.

Script A's optional **per-mailbox hold sweep** is off by default: `-IncludeMailboxHolds`
records aggregate counts by hold state (litigation hold, retention hold, in-place holds,
compliance-tag hold, delay hold, MRM policy assignment, mailbox auditing); adding
`-MailboxDetail` opts into per-mailbox rows (includes UPNs — see the warning above).

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
.\New-PurviewReport.ps1 `
    -Path C:\PurviewDiscovery\PurviewSnapshot-20260628-101500 `
    -OrganizationName "Your Org" -PreparedBy "Your Org" -Classification "Internal"
```

---

## Limitations

Grouped by whether a limit is imposed by the platform or is an intentional design choice.
Each reflects the toolkit as it actually behaves.

**Platform / data source** — imposed by Microsoft 365, not the toolkit:

- **Audit volume ceiling.** `Search-UnifiedAuditLog` returns at most ~50,000 results per
  session. The audit export windows by day (one session per day), so any single day + record
  type exceeding ~50,000 events cannot be fully captured. Days that stop while more results
  remain are **flagged** in `_AuditSampleSummary.csv` (`Truncated` / `TruncationReason`), so an
  incomplete day is never silent. For exhaustive, durable evidence, forward the unified audit
  log to a SIEM (e.g., Microsoft Sentinel) or use the Purview Audit Search Graph API.
- **Audit ingestion latency.** Events can take from minutes to ~24 hours (longer for some
  workloads) to surface in the unified audit log, so a "last N days" run may under-report the
  most recent hours.
- **Audit retention is license-dependent.** Audit Standard retains ~180 days; Audit Premium /
  E5 up to ~1 year. The toolkit cannot query beyond the tenant's retention window.
- **Content Explorer is a computed index.** It requires the Content Explorer List Viewer or
  Content Viewer role (not granted by Compliance Administrator — see Permissions). An access
  error is a permissions gap, not an empty environment, and Content Explorer has its own
  coverage and refresh latency.

**Design scope** — intentional:

- **Read-only, point-in-time snapshot.** The scripts only issue `Get-*` / `Search-*` /
  `Export-*` cmdlets. This is a configuration snapshot for assessment — not continuous
  monitoring and not a compliance attestation.
- **No Microsoft Graph.** Collection uses Security & Compliance and Exchange Online PowerShell
  only, to avoid app-registration / admin-consent friction. Data available only via Graph is
  out of scope.
- **E5 is assumed, not detected.** The scripts don't check licensing; a blank or missing
  section may reflect an unlicensed feature rather than an unconfigured one.
- **Custom classifiers are only partly exportable.** Sensitive information type rule packages
  (the regex/keyword logic) and EDM *schemas* are exported as XML. The EDM data set itself and
  trainable classifiers have no export cmdlet and must be documented manually from the portal.
- **Blank projected properties.** Some CSV columns can be empty where a cmdlet's output shape
  differs across tenants or module versions — a blank value means "not projected here," not
  necessarily "not configured."

**Audit record types.** Endpoint-DLP and disposition-review activity are captured under the
`DLPEndpoint` and `MultiStageDisposition` record types respectively (not `ComplianceDLPEndpoint`
/ `Disposition`, which are not valid `AuditLogRecordType` enum members).

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
