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
PurviewSnapshot-<UTC yyyyMMdd-HHmmss>/
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
| `snapshotLabel` | Optional engagement label from `-SnapshotLabel` (e.g. `Baseline`, `Closeout`) |
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
| `RetentionRecords.AppRetentionRules`, `Legacy.HoldRules`, `CommunicationCompliance.Rules`, `Ediscovery.CaseHoldRules` | `Guid`, `Policy`, `Name` |
| `Governance.RoleGroupMembers` | `RoleGroup`, `MemberName` (toolkit-shaped descriptor rows) |
| `Ediscovery.SecurityFilters` | `FilterName` (the cmdlet's documented identifier — no `Name`/`Guid`) |
| `InformationProtection.IrmConfig` | `Identity` (single configuration object) |
| `Mailboxes.HoldSummary` | `Metric`, `Value` (toolkit-shaped aggregate rows) |
| `Mailboxes.HoldDetail` | `UserPrincipalName` |
| every other batch-3 area | `Guid`, `Name` |
| every batch-2 area not listed | *(empty — generic rule)* |

Batch-3 areas declare `Guid, Name` explicitly (rather than relying on the generic
rule) so the envelope self-describes even if a live object exposes an unexpected
identifier set; the composite degrades to `name:<x>` when no Guid exists.

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
| `Get-RetentionPolicy` (batch 3) | `Guid`, `RetentionPolicyTagLinks`, `IsDefault` | stable key, view columns |
| `Get-RetentionPolicyTag` (batch 3) | `Guid`, `Type`, `AgeLimitForRetention`, `RetentionAction`, `RetentionEnabled`, `MessageClass` | stable key, view columns |
| `Get-JournalRule` (batch 3) | `Guid`, `Enabled`, `Scope`, `Recipient`, `JournalEmailAddress` | stable key, view columns |
| `Get-ProtectionAlert` (batch 3) | `Guid`, `Disabled`, `Category`, `Severity`, `ThreatType`, `Operation`, `NotifyUser`, `AggregationType` | stable key, view columns |
| `Get-ActivityAlert` (batch 3, legacy) | `Guid`, `Disabled`, `Type`, `Category`, `Operation`, `NotifyUser` | stable key, view columns (`CmdletNotAvailable` expected on modern tenants) |
| `Get-InformationBarrierPolicy` (batch 3) | `Guid`, `State`, `AssignedSegment`, `SegmentsAllowed`, `SegmentsBlocked` | stable key, view columns |
| `Get-OrganizationSegment` (batch 3) | `Guid`, `UserGroupFilter` | stable key, view columns |
| `Get-DlpKeywordDictionary` (batch 3) | `Guid`, `Identity`, `Description` | stable key, view columns |
| `Get-RoleGroup` (batch 3) | `Guid`, `DisplayName`, `Description`, `Roles`, `Identity` | stable key, view columns, member enumeration |
| `Get-RoleGroupMember` (batch 3) | member `Name`, `DisplayName`, `Guid`, `RecipientType` | values inside the toolkit-shaped membership descriptors (descriptor column names themselves are toolkit-defined) |
| `Get-HoldCompliancePolicy` (batch 3, legacy) | `Guid`, `Enabled`, `Mode`, `Workload` | stable key, view columns |
| `Get-HoldComplianceRule` (batch 3, legacy) | `Guid`, `Policy`, `Disabled`, `HoldContent`, `HoldDurationDisplayHint` | stable key, view columns |
| `Get-DlpPolicy` (batch 3, legacy EXO DLP) | `Guid`, `State`, `Mode`, `Description` | stable key, view columns |
| `Get-AppRetentionCompliancePolicy` (batch 3) | `Guid`, `Enabled`, `Mode`, `Applications` | stable key, view columns |
| `Get-AppRetentionComplianceRule` (batch 3) | `Guid`, `Policy`, `RetentionDuration`, `RetentionComplianceAction`, `ExpirationDateOption` | stable key, view columns |
| `Get-InsiderRiskPolicy` (batch 3, gated) | `Guid`, `InsiderRiskScenario` | stable key, view columns |
| `Get-SupervisoryReviewPolicyV2` (batch 3, gated) | `Guid`, `Enabled` | stable key, view columns |
| `Get-SupervisoryReviewRule` (batch 3, gated) | `Guid`, `Policy`, `SamplingRate` | stable key, view columns |
| `Get-ComplianceCase` (batch 3, gated) | `Guid`, `CaseType`, `Status`, `Identity` (feeds hold enumeration); `-CaseType AdvancedEdiscovery` parameter value | stable key, view columns, per-case enumeration |
| `Get-CaseHoldPolicy` (batch 3, gated) | `Guid`, `Enabled`, `Mode`, `CaseId` | stable key, view columns |
| `Get-CaseHoldRule` (batch 3, gated) | `Guid`, `Policy`, `ContentMatchQuery` | stable key, view columns |
| `Get-ComplianceSearch` (batch 3, gated) | `Guid`, `CaseName`, `ContentMatchQuery`, `Status` (`Status` is job state — likely diff-noisy; candidate for the volatile register after live validation) | stable key, view columns |
| `Get-ComplianceSecurityFilter` (batch 3, gated) | `FilterName`, `Users`, `Filters`, `Action`, `Description` | **stable key** (`FilterName`), view columns |
| `Get-eDiscoveryCaseAdmin` (batch 3, gated) | `Guid`, `Name`, `DisplayName` | stable key, view columns |
| `Get-IRMConfiguration` (batch 3) | `Identity` (stable key), `AzureRMSLicensingEnabled`, `InternalLicensingEnabled`, `ExternalLicensingEnabled`, `JournalReportDecryptionEnabled`, `SimplifiedClientAccessEnabled`, `TransportDecryptionSetting` | stable key, view columns |
| `Get-RMSTemplate` (batch 3) | `Guid`, `Description`, `Type` | stable key, view columns |
| `Get-EXOMailbox` (batch 3, opt-in sweep) | `UserPrincipalName`, `LitigationHoldEnabled`, `InPlaceHolds`, `ComplianceTagHoldApplied`, `DelayHoldApplied`, `RetentionHoldEnabled`, `RetentionPolicy`, `AuditEnabled` | detail stable key, aggregation inputs, view columns |

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
| `areas[].error` | Message text varies run to run (status is the durable signal) |
| `areas[].objects[].DistributionStatus` | Policy distribution state changes without configuration change |
| `areas[].objects[].DistributionResults` | Same |
| `areas[].objects[].LastStatusUpdateTime` | Same |
| `areas[diffExcluded=true]` | `Audit.OrganizationConfig` (large, operationally noisy) and `Diagnostics.PurviewConfigZip` (opt-in, out-of-band per D6) |

**Why `areas[].count` is NOT in the register (Task 5e).** The register's admission
test is: *does the field change run-to-run without any configuration change?*
`count` fails that test — it moves only when `objects` moves, i.e. exactly when
configuration changed, and a policy count going 14 → 11 between engagement start
and end is precisely what a diff should surface. `count` was originally listed as
"derived; diff the objects", but *derived* is not *volatile*: a derived field that
moves only with real change is safe to compare (and makes a useful summary
headline above the per-object detail). `durationMs` and `error` stay ignored
because they vary with timing and message wording while `status` carries the
durable signal.

## Engine notes

- Collect **both snapshots of a diff pair with the same PowerShell engine**.
  DateTime-valued properties inside tenant objects serialize engine-specifically
  (Windows PowerShell 5.1 emits `\/Date(...)\/`, PowerShell 7 emits ISO strings), and
  JSON whitespace differs between engines. Within one engine, output is
  deterministic.
- Consumers: PowerShell 7's `ConvertFrom-Json` converts ISO-8601 strings to
  `[datetime]` on read; 5.1 keeps strings. Read the raw text when byte-level
  comparison matters.

## Area registry

Batch 2:
`InformationProtection.{SensitivityLabels, LabelPolicies, AutoLabelPolicies, AutoLabelRules}`,
`Classification.{SensitiveInformationTypes, SitRulePackages, EdmSchemas}`,
`Dlp.{Policies, Rules, EndpointGlobalSettings}`,
`RetentionRecords.{Labels, Policies, Rules, EventTypes, AdaptiveScopes, FilePlanAuthorities, FilePlanCategories, FilePlanSubCategories, FilePlanCitations, FilePlanDepartments, FilePlanReferenceIds}`,
`Audit.{UnifiedAuditIngestion, LogRetentionPolicies, OrganizationConfig}`,
`Diagnostics.PurviewConfigZip`.

Batch 3 (D12 coverage expansion, Stop 1 — always-readable):
`Classification.KeywordDictionaries`,
`RetentionRecords.{AppRetentionPolicies, AppRetentionRules}`,
`ExchangeCompliance.{MrmPolicies, MrmTags, JournalRules}`,
`Alerts.{ProtectionAlerts, ActivityAlerts}`,
`InformationBarriers.{Policies, Segments}`,
`Governance.{RoleGroups, RoleGroupMembers}`,
`Legacy.{HoldPolicies, HoldRules, ExchangeDlpPolicies}`.

Batch 3 (Stop 2 — role/licence-gated; a role failure records `AccessDenied`,
never `Empty`):
`InsiderRisk.Policies`,
`CommunicationCompliance.{Policies, Rules}`,
`Ediscovery.{Cases, CaseHoldPolicies, CaseHoldRules, Searches, SecurityFilters, CaseAdmins}`
(enumeration of EXISTING objects only — the AST guard forbids the eDiscovery
mutation verbs),
`InformationProtection.{IrmConfig, RmsTemplates}`.

**Opt-in mailbox sweep** (D12: off by default, aggregate-first):
`Mailboxes.HoldSummary` runs only with `-IncludeMailboxHolds` and records COUNTS
by hold state (`Metric`, `Value`, `Mailboxes`) — no user principal names in the
default evidence. `Mailboxes.HoldDetail` additionally requires `-MailboxDetail`
and emits one row per mailbox **including UPNs** — treat that output as
confidential. Both record `NotAttempted` with the gating reason when their
switches are absent. The sweep is tenant *state* rather than pure policy
configuration; run-to-run deltas reflect mailbox population changes as well as
configuration changes.

Trainable classifiers, data connectors and Compliance Manager have no read cmdlet in
SCC/EXO PowerShell and are documented gaps (D12), not areas. Transport rules are out
for v1 (D12).
