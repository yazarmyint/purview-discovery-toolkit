# Decision Log — discovery refocus

Final decisions governing the toolkit's discovery-only mission. Reviewed
finding-by-finding against the advisory code audit (`docs/AUDIT.md` and the
follow-up mission audit) on the `discovery-refocus` branch; recorded 2026-07-10.
Later batches implement these; this file records the intent they implement.

## D1 — Mission

Pure point-in-time configuration discovery for Microsoft Purview. Zero scores,
grades, findings, recommendations, or "you should" language. Discovery states
WHAT EXISTS; posture judgment is owned by a separate tool
(PurviewPostureAnalyzer).

## D2 — Configuration cardinality is in scope

Counts of configuration objects (e.g. "14 sensitivity labels") are in scope as
configuration cardinality. Activity/event/item counts are not core.

## D3 — Scripts B and C are optional out-of-core companions

Scripts B (`Export-PurviewContentInventory`) and C (`Export-PurviewAuditSample`)
are optional out-of-core companions in this repo, off the core workflow. The
detailed report will render their output as an annex when present; the simple
report omits them. B will later consume A's snapshot for its tag list instead
of re-querying the tenant.

## D4 — No audit "liveness probe" in core

No audit "liveness probe" in core. Companion C covers activity evidence when
explicitly requested.

## D5 — Read-only interpretation (to be disclosed in methodology docs)

`Search-UnifiedAuditLog` creates transient server-side search sessions, and
`Export-PurviewConfig` generates a server-side diagnostic package. Both are
accepted within the `Get-*` / `Export-*` / `Search-*` boundary.

## D6 — Export-PurviewConfig ZIP

Retained, opt-in only, out-of-band corroborating evidence, explicitly excluded
from diff-ready guarantees.

## D7 — ASCII rule scope

Source files ASCII-only; generated reports and data UTF-8;
README/CHANGELOG/docs exempt.

## D8 — PowerShell 5.1 floor

The PowerShell 5.1 floor applies to scripts and the test suite.

## D9 — Approved snapshot architecture (next batch)

One schema-versioned canonical snapshot per run; provenance block (tenant
identity, UPN, module + tool versions, parameters, UTC start/end); status
vocabulary `Success | Empty | AccessDenied | CmdletNotAvailable | Failed |
NotAttempted`; stable identifiers, deterministic ordering, UTC timestamps
throughout; documented volatile-field register; CSVs derived from the snapshot;
large XML/ZIP artifacts as sidecar files referenced by relative path; reports
consume the snapshot only.

## D10 — CLIXML output will be removed

CLIXML output will be removed (migration residue) — next batch, bundled with
the renames.

## D11 — Renames (next batch, one coordinated breaking change)

`-SourceUpn` -> `-UserPrincipalName` (matches PurviewPostureAnalyzer);
`SourceDiscovery-*` folders -> `PurviewSnapshot-*`; new optional
`-SnapshotLabel` (e.g. "Baseline", "Closeout") stamped into provenance and the
report cover; purge migration vocabulary from comments and docs.

## D12 — Coverage v1

**IN:** MRM (`Get-RetentionPolicy` / `Get-RetentionPolicyTag`), journal rules,
IRM config + RMS templates, app retention policies/rules, alert policies
(`Get-ProtectionAlert`), information barriers + org segments, insider risk
policies, communication compliance policies/rules, eDiscovery metadata (cases,
case holds, existing searches, case admins, compliance security filters),
keyword dictionaries, Purview role groups + members, legacy artifacts
(`Get-HoldCompliancePolicy` / `Get-HoldComplianceRule`, legacy EXO
`Get-DlpPolicy`).

**OPT-IN FEATURE, off by default, aggregate-first:** per-mailbox sweeps
(holds, retention assignments, audit state).

**OUT for v1:** transport rules.

**OUT (Graph-only, rendered as documented gaps):** trainable classifiers, data
connectors, Compliance Manager.

## D13 — Test strategy

AST read-only guard generalized to all scripts; status-path characterization
tests on A's wrapper; new-format tests written test-first during the snapshot
build; no golden tests pinning the legacy CSV contract.
