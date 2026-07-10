# Changelog

## Unreleased — discovery-refocus batch 2 (canonical snapshot model)

### Added
- **`scripts/PurviewSnapshot.psm1`** — internal shared module (no manifest/publish):
  connect logic, the `Get-SnapshotArea` collection wrapper, the D9 status classifier,
  stable-key ordering, canonical serialization, provenance builder, and the
  `_manifest.csv` status view writer.
- **`docs/SNAPSHOT-SCHEMA.md`** — draft snapshot schema (`1.0-draft`): document layout,
  envelope fields, status vocabulary, stable-key and ordering rules, sidecar
  conventions, volatile-field register, and engine notes. Freezes at the sandbox
  checkpoint.
- ~43 new offline tests (module unit + integration): status paths incl. AccessDenied
  vs Failed, envelope-for-every-area, 1-item array normalization pinned at JSON-text
  level, byte-identical serialization (file-hash equality), provenance shape, sidecar
  routing, crash-to-partial-snapshot.

### Changed
- **`Invoke-PurviewSourceDiscovery.ps1` now writes ONE canonical `snapshot.json` per
  run** (D9) instead of per-area JSON/CSV/CLIXML triples. Every area emits a durable
  envelope with `Success | Empty | AccessDenied | CmdletNotAvailable | Failed |
  NotAttempted`; permission failures are distinguished from other failures; the three
  formerly hand-rolled blocks (SIT rule packages, EDM schemas, the opt-in
  `Export-PurviewConfig` ZIP) route through the same status recording (closes
  prior-audit S11). Large artifacts land in `sidecars/` and are referenced by
  relative forward-slash paths; the ZIP is marked diff-excluded (D6). A terminating
  error now still yields the snapshot (outcome `Aborted`) with everything collected
  so far. Run-folder timestamps are UTC.
- **Breaking (pre-release):** per-area artifact files are gone (per-area CSVs return
  as *derived views* of the snapshot in Task 5). `_manifest.csv` columns are now
  `Area, Cmdlets, Status, Count, Error, DurationMs`.
- `New-PurviewReport.ps1` still reads the legacy per-area CSVs: a fresh snapshot run
  renders an empty report until the derived views land (Task 5); the report rebuild
  itself is Batch 4.

### Removed
- **CLIXML output (D10).** `Export-Clixml` is gone from the toolkit; the AST guard's
  export allowlist no longer contains it, so it cannot silently return.

## Unreleased — discovery-refocus batch 1

### Changed
- **`New-PurviewReport.ps1` writes the report as UTF-8 without BOM** (was ASCII, which
  replaced non-ASCII tenant data — accented label names, organization names — with `?`).
  Source files remain ASCII-only; generated output is UTF-8 (`docs/DECISIONS.md` D7).
- **`Invoke-PurviewSourceDiscovery.ps1` guarantees the manifest and transcript on failure.**
  The run body is wrapped in `try/finally`: any terminating error still writes the
  `_manifest.csv` rows collected so far and closes the transcript. Previously a mid-run
  terminating error lost the manifest entirely and left the transcript running,
  silently capturing the rest of the console session.
- **`_AuditSampleSummary.csv` gains `Status` and `Error` columns.** A day-slice whose
  `Search-UnifiedAuditLog` loop threw previously recorded `Retrieved`=partial-or-0 with
  `Truncated=False` — indistinguishable from a genuinely quiet day. The day-loop catch now
  stamps `Status=Failed` (D9 vocabulary) plus the exception message in `Error`; clean days
  record `Status=Success`. Columns are now
  `RecordType, Day, Status, Retrieved, Kept, Skipped, Truncated, TruncationReason, Error`.
  **Breaking (pre-release):** second schema change to this file on this branch.
- **The test suite runs under both Windows PowerShell 5.1 and PowerShell 7** (D8). Fixed
  three 5.1 breaks: a multi-argument `Join-Path` (PS 6.2+ only), a `$PSScriptRoot`
  parameter default in `Invoke-Tests.ps1` (empty when evaluated in a param default under
  5.1), and a `.Count` on a single `PSCustomObject` (5.1 lacks the intrinsic member that
  PS Core added in 6.1). Stale test comments corrected (`MaxPerType` -> `MaxPerDay`; the
  dedup test title now names the HashSet implementation, not `Sort-Object`).

### Added
- Offline Pester tests for the report writer (`tests/New-PurviewReport.Tests.ps1`):
  non-ASCII tenant data survives into the HTML, and the file carries no byte order mark.
- Crash-safety test (`tests/Invoke-PurviewSourceDiscovery.Tests.ps1`): a simulated
  mid-run terminating failure still yields `_manifest.csv` and a closed transcript.
- **Generalized read-only AST guard** (`tests/ReadOnlyInvariant.Tests.ps1`) covering all
  four scripts: no tenant-mutating cmdlets; the connect/search/import surface and the
  `Export-*` surface are pinned to the known cmdlet sets. Replaces the former C-only
  guard inside the audit-sample suite.
- **`Export-Artifact` status-path characterization tests**: Success / Empty /
  CmdletNotAvailable / Failed each produce the correct manifest row — the semantics the
  D9 status vocabulary builds on.

### Removed
- `examples/sample-report.html` — posture-era sample (pre-refocus; contained "Posture
  Overview" and "Key Observations & Recommendations" content that contradicts the
  discovery-only mission, see `docs/DECISIONS.md` D1). A discovery sample will be
  regenerated after the report split.

## Unreleased — `Export-PurviewAuditSample.ps1` hardening

### Changed
- **Default window is now the last 7 days** (`-DaysBack` default 30 → 7), matching the unattended
  weekly-snapshot use case and dropping the worst-case volume from ~1.05M to ~245k rows. The
  parameter name and `[ValidateRange(1, 365)]` are unchanged.
- **`_AuditSampleSummary.csv` is now per-record-type-per-day and flags truncation.** Columns are
  `RecordType, Day, Retrieved, Kept, Skipped, Truncated, TruncationReason`
  (`MaxPerDay | SessionCap-50k | MaxPerDay? | none`); previously they were
  `RecordType, RawRecords, Kept, Skipped` (per type). Under the complete-capture model, a day that
  stops while more results still exist — because the per-day budget or the ~50k
  `Search-UnifiedAuditLog` session ceiling was reached — is recorded, not silent. Detection is off
  more-pages-available (`ResultIndex < ResultCount`), not a count==cap coincidence; the run echoes a
  truncated-slice count. As a safety net, a day that stops at the budget but whose response lacks
  `ResultCount` to confirm completeness is flagged `MaxPerDay?` (possibly truncated) rather than
  silently `none`.
- **The audit sample now spans the whole window (S2).** The `-MaxPerType` parameter — a single
  *global* cap across all days — is replaced by **`-MaxPerDay` (default 5,000)**, applied per day.
  Previously the global cap filled on the earliest day(s) of a busy tenant and later days were
  silently dropped, so a "30-day sample" could collapse to the first day or two and misrepresent
  its own window. Now every day is sampled up to `MaxPerDay`, so the sample matches its stated
  window. Worst-case volume is roughly `MaxPerDay × days × record types`; the 50,000-per-session
  `ReturnLargeSet` cap and per-day dedup are unchanged. **Breaking:** `-MaxPerType` is renamed to
  `-MaxPerDay` and its default is lower (5,000 vs 50,000) — update any saved invocations.

### Fixed
- **A malformed audit row no longer aborts the run (S1).** `Expand-AuditRow` guards the `AuditData`
  JSON parse: a null / empty / unparseable payload is warned and skipped instead of terminating the
  script (which, under `$ErrorActionPreference='Stop'`, previously abandoned every not-yet-processed
  record type). The raw record is still preserved in the per-type `.raw.json`, and a per-type
  **Kept / Skipped** tally is written to `_AuditSampleSummary.csv` (with a run total echoed to the
  console) so dropped rows are recorded durably rather than only as a transient warning.
- **Leaner per-type CSV (S12).** The `RawAuditData` column is dropped from the CSV; full-fidelity raw
  records (including the complete `AuditData`) remain in the per-type `.raw.json`, so the raw blob and
  its sensitive detail are no longer double-stored.
- **`-DaysBack` is validated (S15).** `[ValidateRange(1, 365)]` rejects a zero/negative value up front
  instead of silently inverting the window and sampling nothing.

### Added
- Offline Pester v5 test suite under `tests/` (22 tests) covering read-only integrity, the
  `Expand-AuditRow` parse paths, day-windowing, dedup, intra-day multi-page `ReturnLargeSet`
  consumption, the default 7-day window, per-day truncation flagging (MaxPerDay / SessionCap-50k /
  none), and the S1 / S2 / S12 / S15 regressions. Run with `pwsh -File tests/Invoke-Tests.ps1`.
