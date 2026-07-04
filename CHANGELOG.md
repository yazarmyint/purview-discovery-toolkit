# Changelog

## Unreleased — `Export-PurviewAuditSample.ps1` hardening

### Changed
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
- Offline Pester v5 test suite under `tests/` (16 tests) covering read-only integrity, the
  `Expand-AuditRow` parse paths, day-windowing, dedup, intra-day multi-page `ReturnLargeSet`
  consumption, and the S1 / S2 / S12 regressions. Run with `pwsh -File tests/Invoke-Tests.ps1`.
