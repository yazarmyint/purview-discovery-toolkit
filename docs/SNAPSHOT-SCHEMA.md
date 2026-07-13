# Purview Snapshot Schema

> **Status: FROZEN (`schemaVersion: 1.0`, 2026-07-13).** The sandbox checkpoint ran
> Script A read-only against a live tenant (25 areas; Success/Empty/Failed all
> exercised) but the property-shape probe could not be run. Per the checkpoint
> decision, the schema is frozen against **Microsoft-documented property names**,
> and every projection not confirmed against live output is listed in
> [Unverified projections](#unverified-projections) — that list is the bright line
> for later verification. Field names inside `objects[]` follow the cmdlets' own
> output and are captured in full fidelity (no projection at collection time).

One run of `Invoke-PurviewSourceDiscovery.ps1` produces one run folder:

```
SourceDiscovery-<UTC yyyyMMdd-HHmmss>/
  snapshot.json          <- the canonical snapshot (single source of truth)
  _manifest.csv          <- derived status view (one row per area)
  _transcript.log        <- console transcript of the run
  views/<Area>.csv       <- derived per-area views (projected from the snapshot)
  sidecars/<Area>/...    <- large artifacts (XML, ZIP), referenced from the snapshot
```

`snapshot.json` is UTF-8 **without** BOM. CSV views are written by `Export-Csv`
(UTF-8; under Windows PowerShell 5.1 they carry a BOM — views are convenience
artifacts, not diff inputs).

**Derived views.** `views/<Area>.csv` files are projected from the collected
envelopes after the snapshot is written — never from a second tenant call. Each
area's column set is frozen in the collector's view registry; a registered column
absent on the live objects emits **blank** (the caught-later signal for an
[unverified projection](#unverified-projections)), never an error. Views exist
only for areas that collected objects; `Empty` and failed areas are represented by
the snapshot and manifest. `Dlp.EndpointGlobalSettings` (single config object of
unverified shape) and the diff-excluded areas have no view.

## Document layout

```json
{
  "schemaVersion": "1.0-draft",
  "provenance":    { ... },
  "volatileFields": [ "..." ],
  "areas":         [ { ...envelope... } ]
}
```

### Provenance

| Field | Meaning |
|---|---|
| `tool`, `toolVersion` | Generator identity (`purview-discovery-toolkit`) |
| `script` | Collector script name |
| `userPrincipalName` | Account the run was invoked for |
| `snapshotLabel` | Optional engagement label (e.g. `Baseline`, `Closeout`; parameter lands with the D11 renames) |
| `parameters` | Invocation parameters, key-sorted, switches as booleans |
| `connections` | Tenant identity projected from `Get-ConnectionInformation` (`UserPrincipalName`, `TenantID`, `Organization`, `ConnectionUri`, `State`, `IsEopSession` — whichever exist). Volatile token fields are never captured |
| `moduleVersions` | `ExchangeOnlineManagement` version in the session |
| `powerShell` | Engine edition + version the snapshot was collected with |
| `startedUtc`, `endedUtc` | ISO-8601 UTC (`.ToString('o')`), e.g. `2026-07-10T12:00:00.0000000Z` |
| `outcome` | `Completed`, or `Aborted` when a terminating error cut the run short (the snapshot then holds every area collected up to that point) |

### Area envelope

Every attempted area emits an envelope — nothing is silent (D9):

| Field | Meaning |
|---|---|
| `area` | Stable dotted identifier, e.g. `InformationProtection.SensitivityLabels` |
| `cmdlets` | Tenant cmdlets the area relies on |
| `status` | `Success \| Empty \| AccessDenied \| CmdletNotAvailable \| Failed \| NotAttempted` |
| `count` | Number of collected objects. A failure status with a **nonzero** count means *partial collection*: objects arrived before the error and are kept as evidence |
| `error` | Failure message, skip reason, or per-item notes (may be non-null on `Success` when individual sidecar extractions failed) |
| `durationMs` | Collection duration (volatile) |
| `diffExcluded` | `true` for areas outside the diff guarantees (`Audit.OrganizationConfig`, `Diagnostics.PurviewConfigZip` per D6) |
| `stableKeyProperties` | The area's declared composite stable key (see [Stable keys](#stable-keys-per-area)); empty array = the generic rule applies. Self-describing for the diff |
| `sidecars` | `{ name, path, diffExcluded }` — `path` is **relative with forward slashes**, e.g. `sidecars/Classification.SitRulePackages/Contoso Rule Pack.xml` |
| `objects` | The collected objects — **always a JSON array**, including 1-item and 0-item results |

Status classification: a `CommandNotFoundException` from the collect block records
`CmdletNotAvailable`; authorization signals (exception type, or
access-denied/unauthorized/forbidden/401/403/insufficient-permission/role/RBAC text
anywhere in the inner-exception chain) record `AccessDenied`; any other exception
records `Failed`. `NotAttempted` is reserved for areas deliberately skipped by a
parameter (e.g. `Diagnostics.PurviewConfigZip` without `-IncludePurviewConfigZip`).

**Non-terminating errors classify identically (sandbox defect, Task 5b).** Cmdlets
hosted in another module session state (the ExchangeOnlineManagement v3 proxies) do
not see the calling script's `$ErrorActionPreference = 'Stop'`; their failures
arrive on the error stream instead of throwing. The collect error stream is merged
and any `ErrorRecord` classifies through the same rules — an error is **never**
recorded as `Empty`. `Empty` always means "the cmdlet ran and returned nothing":
valid negative evidence.

## Diff-readiness rules (D9)

- **Stable identity.** Areas with a declared `stableKeyProperties` composite key
  use it (below). Otherwise the generic rule: objects are keyed
  `guid:<Guid>|name:<Name>` when a `Guid` property exists; otherwise `name:<Name>`;
  otherwise `id:<Identity>`; otherwise `hash:<SHA-256 of the object's compact
  JSON>` (documented fallback).
- **Deterministic order.** Within an area, objects sort by stable key — ordinal
  comparison, with the object's compact JSON as a tiebreaker so even duplicate keys
  order deterministically. Two serializations of the same in-memory data are
  byte-identical (pinned by test).
- **Arrays are arrays.** A 1-item result serializes as a 1-element array, never a
  bare object (pinned by test at the JSON-text level).
- **Dictionaries are normalized (Task 5a).** Every dictionary reachable through
  object properties, arrays and nested dictionaries is rewritten with **string keys
  in ordinal order** before serialization. Reasons: `ConvertTo-Json` rejects
  non-string dictionary keys on both engines (this failed the whole
  `Classification.SensitiveInformationTypes` area in the sandbox), and hashtables
  enumerate in hash order — randomized per process on PowerShell 7 — which would
  break byte-identical diffs. Key collisions after stringification are kept
  lossless with `#2`, `#3`, … suffixes.
- **Timestamps are ISO-8601 UTC strings** wherever the toolkit generates them.
- **Transport noise is stripped** from objects before serialization:
  `PSComputerName`, `RunspaceId`, `PSShowComputerName`.

## Stable keys per area

Rule objects were flagged by the prior audit as possibly lacking a `Guid` on live
output. Each rule area declares a **documented composite key** — recorded in its
envelope's `stableKeyProperties` — built from whichever declared properties exist
on the object (absent ones are skipped, so the key degrades to
`parentpolicyname:<x>|name:<y>` rather than falling to the content hash). An
object carrying **none** of the declared properties falls back to the generic
rule. Rule names are tenant-unique per policy family, so the composite is
collision-free even without the Guid.

| Area | `stableKeyProperties` (in order) |
|---|---|
| `Dlp.Rules` | `Guid`, `ParentPolicyName`, `Name` |
| `InformationProtection.AutoLabelRules` | `Guid`, `ParentPolicyName`, `Name` |
| `RetentionRecords.Rules` | `Guid`, `Policy`, `Name` |
| every other area | *(empty — generic rule)* |

A diff tool keys objects by the envelope's own `stableKeyProperties` declaration,
so both snapshots of a pair self-describe the same rule.

## Unverified projections

Frozen against Microsoft documentation at the checkpoint, **not** confirmed against
live output (the property-shape probe could not be run). Confirmation path: the
Batch 4 report render against a real snapshot (a blank column is the caught-later
signal), or the Task 4 property-shape probe when the operator can run it. Objects
are captured in full fidelity regardless — a wrong name here affects *ordering
keys and derived-view columns*, never the stored evidence.

| Cmdlet | Unverified properties | Used for |
|---|---|---|
| `Get-Label` | `ParentLabelDisplayName` (prior-audit S9), `Disabled`, `ContentType` | view columns |
| `Get-LabelPolicy` | `Mode`, `Enabled` (prior-audit S9), `Workload`, `Labels` | view columns |
| `Get-AutoSensitivityLabelPolicy` | `Guid`, `Mode`, `ApplySensitivityLabel`, `Workload` | view columns |
| `Get-AutoSensitivityLabelRule` | `Guid`, `ParentPolicyName` | **stable key**, view columns |
| `Get-DlpSensitiveInformationType` | `Id`, `Publisher`, `Type`, `RulePackId` | view columns |
| `Get-DlpSensitiveInformationTypeRulePackage` | `RulePackId`, `Publisher`, `Version` | sidecar descriptor (projected only if present) |
| `Get-DlpCompliancePolicy` | `Enabled`, `ExchangeLocation`, `SharePointLocation`, `OneDriveLocation`, `TeamsLocation`, `EndpointDlpLocation` | view columns |
| `Get-DlpComplianceRule` | `Guid`, `ParentPolicyName` | **stable key**, view columns; also `BlockAccessScope`, `GenerateIncidentReport` (views) |
| `Get-PolicyConfig` | `Identity` / `Name` presence | generic stable key (single object; hash fallback acceptable) |
| `Get-ComplianceTag` | `Notes`, `FilePlanMetadata` | view columns |
| `Get-RetentionCompliancePolicy` | `Mode`, `Workload`, `RestrictiveRetention`; volatile-register names `DistributionStatus`, `DistributionResults`, `LastStatusUpdateTime` | view columns; volatile register |
| `Get-RetentionComplianceRule` | `Guid`, `Policy` | **stable key**, view columns |
| `Get-ComplianceRetentionEventType` | `Guid` | generic stable key |
| `Get-AdaptiveScope` | `LocationType`, `Mode` (prior-audit S9), `FilterQuery`, `Guid` | view columns |
| `Get-FilePlanProperty*` (6 cmdlets) | `Guid` | generic stable key |
| `Get-AdminAuditLogConfig` | `AdminAuditLogEnabled` | view column |
| `Get-UnifiedAuditLogRetentionPolicy` | `Name` (stable key; may be `Policy`), `Priority`, `RecordTypes`, `Operations`, `UserIds`, `RetentionDuration` | generic stable key, view columns |
| `Get-ConnectionInformation` | `UserPrincipalName`, `TenantID`, `Organization`, `ConnectionUri`, `State`, `IsEopSession` | provenance (defensive — absent names are skipped) |

**Verified by the sandbox run** (no longer suspect): the `Export-PurviewConfig`
component tokens `DLP, MIPLabels, ClassificationAndTextExtraction, DLM` (prior-audit
S10 — the ZIP exported successfully), and area-level viability/counts for all 25
areas.

## Volatile-field register

Fields a diff of two snapshots must ignore (also embedded in every snapshot under
`volatileFields`):

| Path | Reason |
|---|---|
| `provenance` | Run-specific by definition (timestamps, engine, versions). Diff tools should still *compare* `connections` tenant identity and warn on mismatch |
| `areas[].durationMs` | Timing noise |
| `areas[].count` | Derived from `objects`; diff the objects |
| `areas[].error` | Message text varies run to run (status is the durable signal) |
| `areas[].objects[].DistributionStatus` | Policy distribution state changes without configuration change |
| `areas[].objects[].DistributionResults` | Same |
| `areas[].objects[].LastStatusUpdateTime` | Same |
| `areas[diffExcluded=true]` | `Audit.OrganizationConfig` (large, operationally noisy) and `Diagnostics.PurviewConfigZip` (opt-in, out-of-band per D6) |

## Engine notes

- Collect **both snapshots of a diff pair with the same PowerShell engine**.
  DateTime-valued properties inside tenant objects serialize engine-specifically
  (Windows PowerShell 5.1 emits `\/Date(...)\/`, PowerShell 7 emits ISO strings), and
  JSON whitespace differs between engines. Within one engine, output is
  deterministic.
- Consumers: PowerShell 7's `ConvertFrom-Json` converts ISO-8601 strings to
  `[datetime]` on read; 5.1 keeps strings. Read the raw text when byte-level
  comparison matters.

## Area registry (batch 2)

`InformationProtection.{SensitivityLabels, LabelPolicies, AutoLabelPolicies, AutoLabelRules}`,
`Classification.{SensitiveInformationTypes, SitRulePackages, EdmSchemas}`,
`Dlp.{Policies, Rules, EndpointGlobalSettings}`,
`RetentionRecords.{Labels, Policies, Rules, EventTypes, AdaptiveScopes, FilePlanAuthorities, FilePlanCategories, FilePlanSubCategories, FilePlanCitations, FilePlanDepartments, FilePlanReferenceIds}`,
`Audit.{UnifiedAuditIngestion, LogRetentionPolicies, OrganizationConfig}`,
`Diagnostics.PurviewConfigZip`.

Trainable classifiers, data connectors and Compliance Manager have no read cmdlet in
SCC/EXO PowerShell and are documented gaps (D12), not areas.
