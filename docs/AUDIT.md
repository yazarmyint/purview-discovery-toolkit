# Purview Discovery Toolkit — Advisory Code Audit

_Advisory findings only. No code was changed as part of this audit. Scope: the four
discovery scripts after the discovery-only refocus — A `Invoke-PurviewSourceDiscovery.ps1`,
B `Export-PurviewContentInventory.ps1`, C `Export-PurviewAuditSample.ps1`,
E `New-PurviewReport.ps1`._

> **Resolution status (updated after the audit):** Script C findings **S1, S2, S12** are
> **resolved**, and the **S15 `-DaysBack` item** is resolved — see commit `0deb408` and
> [CHANGELOG.md](../CHANGELOG.md). Entries below are annotated in place; all other findings
> (S3–S11, S13–S14, and the remaining S15 items) remain open.

## Method
Cmdlet, parameter, enum, and return-shape claims below were verified against the current
`learn.microsoft.com` PowerShell reference rather than asserted from memory. Verified facts
used in this audit:

- `Export-ContentExplorerData` **has a real `-Aggregate` switch**; its output is an array
  where **item 0 is a summary object** carrying `TotalCount` / `MorePagesAvailable` /
  `RecordsReturned` / `PageCookie`, and items `1..n` are records. Reconnect-and-resume via
  the last `PageCookie` is the **documented** pattern.
- `Get-AdaptiveScope` and `Export-PurviewConfig` **both exist** (neither is dead code).
  `Export-PurviewConfig` returns a ZIP as a `byte[]` and declares `-Confirm`/`-WhatIf`.
- `Search-UnifiedAuditLog`: `ResultSize` max **5,000**; a single search (SessionId) processes
  a max of **50,000** records via page retrieval. `MultiStageDisposition`,
  `SensitivityLabelAction`, and `SensitivityLabeledFileAction` are valid record-type enum
  members (canonical MIP label type is `MipLabel`).

## Read-only integrity — PASS (one item flagged)
Every tenant-touching call is `Get-*` / `Search-*` / `Export-*`. No
`Set/New/Remove/Enable/Disable/Add/Update` against tenant state anywhere. Local
`New-Item`/`Set-Content`/`Out-File` write only inside the run folder. **One ambiguity,
flagged not failed:** `Export-PurviewConfig` (A, line 228) declares `SupportsShouldProcess`
(`-Confirm`/`-WhatIf`) — the only such cmdlet in the toolkit — but functionally it *exports*
diagnostics (returns a `byte[]`) and does not mutate state. Invariant holds.

---

## Should fix (ranked by severity)

### S1 — C: one malformed `AuditData` row aborts the entire audit run
> **✅ Resolved in `0deb408`** — `Expand-AuditRow` guards the parse (null/empty/malformed → warn + skip, never terminate); a durable per-type Kept/Skipped tally is written to `_AuditSampleSummary.csv`. See CHANGELOG.md.
- **Where:** `Export-PurviewAuditSample.ps1` line 81 (`Expand-AuditRow` in a pipeline) → lines 39–41 (`ConvertFrom-Json`).
- **What's wrong:** `$ErrorActionPreference='Stop'` (line 26) is global, and the
  `$all | … | ForEach-Object { Expand-AuditRow … }` at line 81 is not inside a try/catch.
  `Expand-AuditRow` runs `$rec.AuditData | ConvertFrom-Json` with no guard, so one record
  with null/empty/non-JSON `AuditData` throws a terminating error that kills the script.
- **Why it matters:** The per-day `Search-UnifiedAuditLog` loop *is* wrapped (67–76), so the
  run looks resilient — but post-processing isn't. One bad row abandons every not-yet-processed
  record type (earlier CSVs survive; later ones are lost, no summary).
- **Fix:** Wrap the `Expand-AuditRow` body in try/catch (skip+warn), or guard
  `if ($rec.AuditData) { … }` and emit the row with empty policy/SIT fields on failure.

### S2 — C: `-MaxPerType` is a global budget, biasing the sample to the start of the window
> **✅ Resolved in `0deb408`** — replaced with a per-day budget `-MaxPerDay` (default 5000); the day loop now always traverses the full window, and a test pins the per-day distribution. Breaking param rename. See CHANGELOG.md.
- **Where:** `Export-PurviewAuditSample.ps1` lines 63 & 73 (`$all.Count -lt $MaxPerType` gates both the day loop and the page loop).
- **What's wrong:** `$all` accumulates across all days for a record type; both loops stop once
  the total hits `MaxPerType` (default 50,000). A busy early day can exhaust the budget so
  later days are never queried.
- **Why it matters:** A single search session caps at 50,000; the header comment frames 50k as
  a per-session/per-day cap, but the code enforces it as a per-type total. On an active tenant
  the "30-day sample" silently becomes "the first day or two" — a misleading evidence artifact.
- **Fix:** Reset the counter per day, or iterate newest-day-first, or document `MaxPerType`
  as a global ceiling and log when a day is skipped because the budget was spent.

### S3 — A: transcript is never closed if a terminating error occurs
- **Where:** `Invoke-PurviewSourceDiscovery.ps1` line 28 (`Start-Transcript`) / line 240 (`Stop-Transcript`), no try/finally; `$ErrorActionPreference='Stop'` line 21.
- **What's wrong:** `Start-Transcript` runs at line 28; `Connect-*` (34–38) and other top-level
  statements are after it and outside any try/finally. Any uncaught terminating error skips
  line 240, leaving the transcript running in the session.
- **Why it matters:** The open transcript keeps capturing subsequent unrelated console activity
  into the log, and the run ends with no manifest (line 237 also skipped). Silent and surprising.
- **Fix:** Wrap the body in `try { … } finally { Stop-Transcript -ErrorAction SilentlyContinue }`.

### S4 — A: no session-drop resilience on long runs
- **Where:** `Invoke-PurviewSourceDiscovery.ps1` `Export-Artifact` (42–79); connect only at 34–38.
- **What's wrong:** IPPS/EXO tokens live ~1 hour; a large-tenant run can exceed that. Once the
  session drops, every remaining `Export-Artifact` hits the catch (74) and records `Failed: …`.
  There is no reconnect (contrast B, which reconnects+resumes).
- **Why it matters:** Instead of one recoverable hiccup you get a manifest full of `Failed`
  rows and a half-empty export, with no indication the cause was a single expiry.
- **Fix:** In `Export-Artifact`'s catch, detect auth/token errors and reconnect+retry once
  (mirror B's `Get-PagedRecords`), honoring `-ReuseExistingSession`.

### S5 — Cross-cutting: duplicated infrastructure, no shared module
- **Where:** A/B/C.
- **What's wrong:** `C:\PurviewDiscovery` default (A16/B23/C19), connect logic (A inline /
  B `Connect-Ipps` / C inline), and filename sanitisation (A `Get-SafeName` line 22 vs B inline
  regex line 91 vs none in C) are each re-implemented and already diverging. Logging conventions
  differ too (A: transcript+manifest+colour; B/C: colour only).
- **Why it matters:** The read-only invariant and the output contract are the product's value;
  enforcing them in one place, not three, is how they stay true over time.
- **Fix:** Extract `PurviewToolkit.psm1` — `Connect-Purview`, `Get-SafeName`, `New-RunFolder`,
  `Write-Manifest` — imported by A/B/C.

### S6 — Cross-cutting: zero automated tests
- **Where:** all.
- **What's wrong / why it matters:** No Pester. Highest-risk unit is **E** — a pure,
  deterministic CSV→HTML transform where a renamed column or flipped threshold silently
  corrupts the client-facing report (see S7/S8) with no error.
- **Fix (priority):** (1) E — fixture CSVs → assert KPI counts, observation firing, section
  presence; (2) B `Get-PagedRecords` — mock summary/record pages, assert termination/counts;
  (3) C `Expand-AuditRow` + day-windowing/dedup — mock `Search-UnifiedAuditLog`; (4) A
  `Export-Artifact` — mock `Get-Command`/scriptblocks for each status path.

---

## Nice to have

### S7 — E: silent coupling to A's CSV column contract
Baseline reads fixed columns (`EncryptionEnabled`, `IsCustom`, `FilePlan`, `Mode`, `ParentLabel`).
A missing/blank column yields `$null` (no error), so counts read 0 and observations like
"No labels apply encryption" can fire on **missing data** rather than real absence. Distinguish
"column absent" from "value false," or validate expected headers. (S6's E-tests would catch this.)

### S8 — E: DLP `Mode` buckets can under-count
Metrics block buckets enforce=`Mode -eq 'Enable'`, test=`Mode -like 'Test*'`,
disabled=`Mode -eq 'Disable'`. `Get-DlpCompliancePolicy` `Mode` also includes `PendingDeletion`;
such policies fall into no bucket, so the three can sum to less than `$dlpTotal`. The donut
normalizes and still renders, but the narrative omits them. Add an "other" bucket or reconcile.

### S9 — A: unverified CSV projections (silently-empty columns)
`AdaptiveScopes` CsvSelect `@('Name','Guid','LocationType','Mode')` (line 201): `Get-AdaptiveScope`
exists, but its output likely has no `Mode` and names location `LocationTypes` — those columns
will be blank. Same property-name risk for `ParentLabelDisplayName` (87) and label-policy
`Mode`/`Enabled` (93). Non-fatal, but blanks propagate into E (→ S7). Verify each projected
property against live output.

### S10 — A: `Export-PurviewConfig` component tokens unverified
Line 228: `-Components DLP,MIPLabels,ClassificationAndTextExtraction,DLM`. Docs confirm the
cmdlet and show `DLP`/`MIPLabels`; `ClassificationAndTextExtraction` and `DLM` are not shown as
valid tokens. An invalid token likely fails the call (caught, warns). Verify accepted
`-Components` values. Behind opt-in `-IncludePurviewConfigZip`, so low blast radius.

### S11 — A: absent SIT/EDM cmdlets leave no manifest trace
Lines 115–130 (SIT rule packages) & 135–148 (EDM): the manifest `.Add` is inside the
`if (Get-Command …)` guard, so a missing cmdlet records nothing — unlike `Export-Artifact`,
which writes a `CmdletNotAvailable` row. Add an else-branch manifest row for parity.

### S12 — C: CSV duplicates the raw audit blob
> **✅ Resolved in `0deb408`** — `RawAuditData` dropped from the per-type CSV; `raw.json` retains full fidelity.
Line 54 (`RawAuditData = $rec.AuditData`) is written to `$rt.csv` (82) *and* to `$rt.raw.json`
(83). The CSV then carries full nested audit JSON per row — heavy, hard to read, doubly-stores
sensitive detail. Drop `RawAuditData` from the CSV (raw.json preserves fidelity).

### S13 — B: misattributed reconnect on permission errors
Lines 66–70: any exception in `Get-PagedRecords` triggers "reconnecting and resuming…",
including the Content-Explorer-role `AccessDenied` the README calls out. Reconnect can't fix a
missing role and just fails again with a misleading message. Inspect the exception; reconnect
only on auth/token errors, surface role errors distinctly.

### S14 — B: no manifest/transcript; stray empty folder
B writes only `_ContentInventorySummary.csv` (+ optional detail JSON) — no manifest/transcript,
inconsistent with A. Also the `TrainableClassifier`-with-no-`-Tags` early `return` (line 42)
happens after `New-Item` created the folder (line 34), leaving an empty `ContentInventory-*` dir.

### S15 — E & C: PowerShell hygiene / minor
> **◑ Partially resolved in `0deb408`** — the C `$DaysBack` `[ValidateRange(1,365)]` guard is done. The C `MIPLabel` casing and the inaccurate `.NOTES` "silently skipped" wording, plus all E and A items in this bucket, remain open (intentionally deferred).
- **E:** `$dlpBlk` is computed but never used (dead variable). `Test-True`'s inline `(?i)`
  (line 42) is redundant — `-match` is already case-insensitive.
- **E:** `Enc` doesn't escape `'`; safe today (user text lands only in element *content*;
  attributes use constant palette values) but fragile if data is ever interpolated into an
  attribute — defense-in-depth note.
- **C:** `MIPLabel` (line 22) binds case-insensitively to canonical `MipLabel` — works, but
  align casing. `$DaysBack` has no `[ValidateRange]` (a negative inverts the window → 0 results).
  Header comment "an invalid RecordType is *silently* skipped" is slightly off — it warns per-day.
- **A:** CSV formula-injection — names beginning `= + - @` are written unescaped; low risk
  (admin-authored), a hardening note only.

---

## Per-script verdict

| Script | Read-only | State | Headline items |
|---|---|---|---|
| **A** Discovery | PASS | Solid `Export-Artifact` resilience; best manifest discipline | S3 transcript, S4 no reconnect, S9/S10/S11 traceability & property risks |
| **B** Content Inv. | PASS | Paging/reconnect-resume matches MS-documented pattern (a strength) | S13 misattributed reconnect, S14 no manifest |
| **C** Audit | PASS | Correct enums & 50k/day segmentation | **S1 abort-on-bad-row**, **S2 sampling bias**, S12 CSV bloat |
| **E** Report | PASS | Pure/deterministic; good offline design; refocus verified clean & parsing | S7 contract coupling, S8 Mode buckets, S15 dead var |

**Biggest risks:** S1 (silent run-abort) and S2 (biased sample) in C corrupt the *evidence*;
S7/S6 in E silently corrupt the *client report*.
