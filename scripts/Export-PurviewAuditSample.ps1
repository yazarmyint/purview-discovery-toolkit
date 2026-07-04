#Requires -Version 5.1
<#
.SYNOPSIS
    Sample unified audit log export for DLP / labelling / disposition activity over a
    date window. Provides override-justification and activity evidence. Run against the
    SOURCE tenant. Audit output includes object IDs (file/message identifiers), user IDs,
    and policy/SIT match detail - treat as confidential.
.NOTES
    RecordType values must match the canonical AuditLogRecordType enum (an invalid value
    fails parameter binding and that type is silently skipped). Endpoint DLP = 'DLPEndpoint'
    (not 'ComplianceDLPEndpoint'); disposition review = 'MultiStageDisposition' (not 'Disposition').
    UAL (Audit Standard) retains ~180 days; Audit Premium / E5 up to ~1 year. ReturnLargeSet
    caps at 50,000 results per session, so the window is segmented per day with a fresh
    SessionId. -MaxPerDay bounds the rows kept for each day (default 5,000), so every day in the
    window is represented rather than the sample front-loading onto the busiest early days;
    worst-case volume is roughly MaxPerDay x days x record types. For full, durable evidence
    forward UAL to SIEM (Sentinel) - this is a sample.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceUpn,
    [string]$OutputRoot = "C:\PurviewDiscovery",
    [ValidateRange(1, 365)][int]$DaysBack = 30,
    [string[]]$RecordTypes = @('ComplianceDLPSharePoint','ComplianceDLPExchange','DLPEndpoint',
                               'SensitivityLabelAction','SensitivityLabeledFileAction','MIPLabel','MultiStageDisposition'),
    [int]$MaxPerDay = 5000,
    [switch]$ReuseExistingSession
)
$ErrorActionPreference = 'Stop'
Import-Module ExchangeOnlineManagement -ErrorAction Stop
if (-not $ReuseExistingSession) { Connect-ExchangeOnline -UserPrincipalName $SourceUpn -ShowBanner:$false }

$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $OutputRoot "AuditSample-$stamp"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# UAL stores entries in UTC; build the window in UTC for cross-system correlation.
$endUtc   = (Get-Date).ToUniversalTime()
$startUtc = $endUtc.AddDays(-$DaysBack)
Write-Host "Window (UTC): $($startUtc.ToString('u')) -> $($endUtc.ToString('u'))" -ForegroundColor Cyan

function Expand-AuditRow($rec,[string]$rt) {
    # Guard the parse: a null / empty / malformed AuditData payload must warn + skip, never
    # terminate the run. Script-level $ErrorActionPreference='Stop' would otherwise let one bad
    # row abort every not-yet-processed record type. The raw record is still preserved in the
    # per-type .raw.json, so nothing is lost for forensic follow-up. See docs/AUDIT.md S1.
    if ([string]::IsNullOrWhiteSpace($rec.AuditData)) {
        Write-Warning "  Skipped a row with empty AuditData (Identity=$($rec.Identity); $($rec.CreationDate))."
        return
    }
    try {
        $d = $rec.AuditData | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "  Skipped a row with unparseable AuditData (Identity=$($rec.Identity); $($rec.CreationDate)): $($_.Exception.Message)"
        return
    }
    $isDlp = ($rt -like 'ComplianceDLP*') -or ($rt -eq 'DLPEndpoint')
    $policy = ''; $sit = ''
    if ($isDlp) {
        # PolicyDetails[].Rules[].ConditionsMatched.SensitiveInformation[].SensitiveInformationTypeName
        $policy = ($d.PolicyDetails.PolicyName -join ';')
        $sit    = ($d.PolicyDetails.Rules.ConditionsMatched.SensitiveInformation.SensitiveInformationTypeName -join ';')
    }
    # The lean CSV carries only the projected fields; full fidelity is preserved in the per-type
    # .raw.json (raw records, incl. the complete AuditData). Keeping the raw blob out of the CSV
    # avoids bloat and a second copy of sensitive detail. See docs/AUDIT.md S12.
    [pscustomobject]@{
        CreationDate = $rec.CreationDate
        RecordType   = $(if ($rec.RecordType) { $rec.RecordType } else { $rt })   # -Formatted gives a string; fall back to the queried type
        Operation    = $d.Operation; UserId = $d.UserId
        Workload     = $d.Workload;  ObjectId = $d.ObjectId
        PolicyName   = $policy; SitName = $sit
    }
}

# Per-type tally so the count of rows dropped by the AuditData parse guard (S1) is durable, not
# just a transient warning. Written to _AuditSampleSummary.csv and echoed as a run total.
$summary = [System.Collections.Generic.List[object]]::new()
$totalKept = 0; $totalSkipped = 0

foreach ($rt in $RecordTypes) {
    Write-Host "Searching record type: $rt ..." -ForegroundColor Yellow
    $all = [System.Collections.Generic.List[object]]::new()
    # Segment per-day with a fresh SessionId (a single ReturnLargeSet session returns up to
    # 50,000 records). The budget is applied PER DAY, so the whole window is always traversed
    # and a busy early day cannot starve later days of representation. See docs/AUDIT.md S2.
    $day = $startUtc
    while ($day -lt $endUtc) {
        $winStart = $day
        $winEnd   = $day.AddDays(1); if ($winEnd -gt $endUtc) { $winEnd = $endUtc }
        $sid = [guid]::NewGuid().ToString()
        $dayStart = $all.Count                                        # rows collected before this day
        try {
            do {
                $page = Search-UnifiedAuditLog -StartDate $winStart -EndDate $winEnd -RecordType $rt -Formatted `
                            -SessionId $sid -SessionCommand ReturnLargeSet -ResultSize 5000
                if ($page) { $page | ForEach-Object { $all.Add($_) } }
            # Terminate on an empty page, or once this day has reached its per-day budget.
            } while ($page -and @($page).Count -gt 0 -and ($all.Count - $dayStart) -lt $MaxPerDay)
        } catch {
            Write-Warning "  $rt $($winStart.ToString('yyyy-MM-dd')) failed: $($_.Exception.Message)"
        }
        $day = $day.AddDays(1)
    }

    if ($all.Count) {
        $deduped = @($all | Sort-Object Identity -Unique)                                          # dedupe (ReturnLargeSet is unsorted)
        $rows    = @($deduped | ForEach-Object { Expand-AuditRow $_ $rt })
        $kept    = $rows.Count
        $skipped = $deduped.Count - $kept                                                          # rows dropped by the AuditData parse guard (S1)
        $rows | Export-Csv (Join-Path $outDir "$rt.csv") -NoTypeInformation -Encoding utf8
        $all  | ConvertTo-Json -Depth 8 | Out-File (Join-Path $outDir "$rt.raw.json") -Encoding utf8
        $skipNote = if ($skipped) { " ($skipped skipped - unparseable AuditData)" } else { '' }
        Write-Host "  $rt : $kept records$skipNote." -ForegroundColor Green
    } else { $kept = 0; $skipped = 0; Write-Host "  $rt : 0 records." -ForegroundColor DarkGray }
    $summary.Add([pscustomobject]@{ RecordType = $rt; RawRecords = @($all).Count; Kept = $kept; Skipped = $skipped })
    $totalKept += $kept; $totalSkipped += $skipped
}
$summary | Export-Csv (Join-Path $outDir '_AuditSampleSummary.csv') -NoTypeInformation -Encoding utf8
Write-Host "Saved: $outDir" -ForegroundColor Cyan
Write-Host "Totals: $totalKept kept, $totalSkipped skipped (unparseable AuditData). Summary: $(Join-Path $outDir '_AuditSampleSummary.csv')" -ForegroundColor Cyan
