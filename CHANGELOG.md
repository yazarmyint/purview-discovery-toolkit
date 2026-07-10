# Changelog

## Unreleased — discovery-refocus batch 1

### Changed
- **`New-PurviewReport.ps1` writes the report as UTF-8 without BOM** (was ASCII, which
  replaced non-ASCII tenant data — accented label names, organization names — with `?`).
  Source files remain ASCII-only; generated output is UTF-8 (`docs/DECISIONS.md` D7).

### Added
- Offline Pester tests for the report writer (`tests/New-PurviewReport.Tests.ps1`):
  non-ASCII tenant data survives into the HTML, and the file carries no byte order mark.

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
