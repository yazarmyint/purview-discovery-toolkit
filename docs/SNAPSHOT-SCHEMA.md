# Purview Snapshot Schema

> **Status: DRAFT (`schemaVersion: 1.0-draft`).** The schema freezes to `1.0` only
> after the sandbox checkpoint verifies every projected property name against live
> cmdlet output (DECISIONS.md D9, batch 2 Task 5). Until then, field names inside
> `objects[]` follow the cmdlets' own output and are not individually guaranteed.

One run of `Invoke-PurviewSourceDiscovery.ps1` produces one run folder:

```
SourceDiscovery-<UTC yyyyMMdd-HHmmss>/
  snapshot.json          <- the canonical snapshot (single source of truth)
  _manifest.csv          <- derived status view (one row per area)
  _transcript.log        <- console transcript of the run
  sidecars/<Area>/...    <- large artifacts (XML, ZIP), referenced from the snapshot
```

`snapshot.json` is UTF-8 **without** BOM. CSV views are written by `Export-Csv`
(UTF-8; under Windows PowerShell 5.1 they carry a BOM — views are convenience
artifacts, not diff inputs).

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
| `count` | Number of collected objects (derived; diff by `objects`, not `count`) |
| `error` | Failure message, skip reason, or per-item notes (may be non-null on `Success` when individual sidecar extractions failed) |
| `durationMs` | Collection duration (volatile) |
| `diffExcluded` | `true` for areas outside the diff guarantees (`Audit.OrganizationConfig`, `Diagnostics.PurviewConfigZip` per D6) |
| `sidecars` | `{ name, path, diffExcluded }` — `path` is **relative with forward slashes**, e.g. `sidecars/Classification.SitRulePackages/Contoso Rule Pack.xml` |
| `objects` | The collected objects — **always a JSON array**, including 1-item and 0-item results |

Status classification: a `CommandNotFoundException` from the collect block records
`CmdletNotAvailable`; authorization signals (exception type, or
access-denied/unauthorized/forbidden/401/403/insufficient-permission/role/RBAC text
anywhere in the inner-exception chain) record `AccessDenied`; any other exception
records `Failed`. `NotAttempted` is reserved for areas deliberately skipped by a
parameter (e.g. `Diagnostics.PurviewConfigZip` without `-IncludePurviewConfigZip`).

## Diff-readiness rules (D9)

- **Stable identity.** Objects are keyed `guid:<Guid>|name:<Name>` when a `Guid`
  property exists; otherwise `name:<Name>`; otherwise `id:<Identity>`; otherwise
  `hash:<SHA-256 of the object's compact JSON>` (documented fallback).
- **Deterministic order.** Within an area, objects sort by stable key — ordinal
  comparison, with the object's compact JSON as a tiebreaker so even duplicate keys
  order deterministically. Two serializations of the same in-memory data are
  byte-identical (pinned by test).
- **Arrays are arrays.** A 1-item result serializes as a 1-element array, never a
  bare object (pinned by test at the JSON-text level).
- **Timestamps are ISO-8601 UTC strings** wherever the toolkit generates them.
- **Transport noise is stripped** from objects before serialization:
  `PSComputerName`, `RunspaceId`, `PSShowComputerName`.

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
