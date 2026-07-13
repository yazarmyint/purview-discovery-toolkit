#Requires -Version 5.1
<#
.SYNOPSIS
    Sample unified audit log export for DLP / labelling / disposition activity over a
    date window. Provides override-justification and activity evidence. Run against the
    tenant under assessment. Audit output includes object IDs (file/message identifiers),
    user IDs, and policy/SIT match detail - treat as confidential.
.NOTES
    RecordType values must match the canonical AuditLogRecordType enum (an invalid value
    fails parameter binding and that type is silently skipped). Endpoint DLP = 'DLPEndpoint'
    (not 'ComplianceDLPEndpoint'); disposition review = 'MultiStageDisposition' (not 'Disposition').
    UAL (Audit Standard) retains ~180 days; Audit Premium / E5 up to ~1 year. ReturnLargeSet
    caps at 50,000 results per session, so the window is segmented per day with a fresh
    SessionId. The run captures the last -DaysBack days (default 7). -MaxPerDay bounds the rows kept
    for each day (default 5,000) as a runaway guardrail, so every day in the window is represented;
    worst-case volume is roughly MaxPerDay x days x record types. _AuditSampleSummary.csv records
    Retrieved / Kept / Skipped per record-type-per-day and flags any day where collection stopped
    while more results remained (Truncated + TruncationReason: MaxPerDay | SessionCap-50k | none, or
    MaxPerDay? when the budget was hit but the response lacked ResultCount to confirm completeness),
    so an incomplete day is never silent. Each day row also carries Status (Success | Failed) and
    Error: a day whose search threw records the exception durably instead of looking like a quiet
    day. For full, durable evidence forward UAL to SIEM (Sentinel).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [string]$OutputRoot = "C:\PurviewDiscovery",
    [ValidateRange(1, 365)][int]$DaysBack = 7,
    [string[]]$RecordTypes = @('ComplianceDLPSharePoint','ComplianceDLPExchange','DLPEndpoint',
                               'SensitivityLabelAction','SensitivityLabeledFileAction','MIPLabel','MultiStageDisposition'),
    [int]$MaxPerDay = 5000,
    [switch]$ReuseExistingSession
)
$ErrorActionPreference = 'Stop'
Import-Module ExchangeOnlineManagement -ErrorAction Stop
if (-not $ReuseExistingSession) { Connect-ExchangeOnline -UserPrincipalName $UserPrincipalName -ShowBanner:$false }

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

# _AuditSampleSummary.csv makes coverage durable: one row per record-type-per-day recording
# Status / Retrieved / Kept / Skipped, flagging any day where we stopped fetching while more
# results still existed (Truncated + TruncationReason), and carrying the exception message
# (Error) when the day's search threw. Under the "complete capture" model a truncated or
# failed day is an incomplete snapshot, so it must never be silent. See docs/AUDIT.md S1/S2.
$summary   = [System.Collections.Generic.List[object]]::new()
$totalKept = 0; $totalSkipped = 0; $truncCount = 0

foreach ($rt in $RecordTypes) {
    Write-Host "Searching record type: $rt ..." -ForegroundColor Yellow
    $seenIds  = [System.Collections.Generic.HashSet[string]]::new()   # per-type dedup key (Identity)
    $allRaw   = [System.Collections.Generic.List[object]]::new()      # raw records -> .raw.json
    $keptRows = [System.Collections.Generic.List[object]]::new()      # projected rows -> .csv
    $typeKept = 0; $typeSkipped = 0

    # Segment per-day with a fresh SessionId (a single ReturnLargeSet session returns up to
    # 50,000 records). The budget is applied PER DAY, so the whole window is always traversed
    # and a busy early day cannot starve later days of representation. See docs/AUDIT.md S2.
    $day = $startUtc
    while ($day -lt $endUtc) {
        $winStart = $day
        $winEnd   = $day.AddDays(1); if ($winEnd -gt $endUtc) { $winEnd = $endUtc }
        $sid = [guid]::NewGuid().ToString()
        $dayRaw = [System.Collections.Generic.List[object]]::new()
        $resultCount = 0; $maxIndex = 0                              # ReturnLargeSet paging progress
        $dayError = $null                                            # set when this day's search throws
        try {
            do {
                $page = Search-UnifiedAuditLog -StartDate $winStart -EndDate $winEnd -RecordType $rt -Formatted `
                            -SessionId $sid -SessionCommand ReturnLargeSet -ResultSize 5000
                if ($page) {
                    $page | ForEach-Object {
                        $dayRaw.Add($_)
                        # ResultIndex = this record's position; ResultCount = total matching for the day
                        # (ResultIndex is -1 on an internal search timeout, so ignore non-positive values).
                        if ($_.ResultCount) { $rc = [int]$_.ResultCount; if ($rc -gt $resultCount) { $resultCount = $rc } }
                        if ($_.ResultIndex) { $ix = [int]$_.ResultIndex; if ($ix -gt $maxIndex)    { $maxIndex    = $ix } }
                    }
                }
            # Terminate on an empty page, or once this day has reached its per-day budget.
            } while ($page -and @($page).Count -gt 0 -and $dayRaw.Count -lt $MaxPerDay)
        } catch {
            # Durable failure capture: the summary row gets Status=Failed + the message, so
            # a failed or partially-retrieved day is never mistaken for a quiet day.
            $dayError = $_.Exception.Message
            Write-Warning "  $rt $($winStart.ToString('yyyy-MM-dd')) failed: $($_.Exception.Message)"
        }

        # Truncation is detected off more-pages-available (we retrieved fewer than matched), NOT off a
        # count==cap coincidence. If we stopped at our own budget it's MaxPerDay; if the platform
        # stopped feeding us first (the ~50k per-session ceiling) it's SessionCap-50k.
        $retrieved     = $dayRaw.Count
        $hitBudget     = $retrieved -ge $MaxPerDay                    # loop stopped at our budget, not an empty page
        $moreAvailable = ($resultCount -gt 0) -and ($maxIndex -lt $resultCount)
        $reason = 'none'
        if ($moreAvailable) {
            $reason = if ($hitBudget) { 'MaxPerDay' } else { 'SessionCap-50k' }
        }
        elseif ($hitBudget -and $resultCount -le 0) {
            # We stopped at the budget but the response carried no ResultCount to confirm the day was
            # exhausted (ResultIndex/ResultCount are documented as always-populated general properties,
            # but -Formatted / older modules are not guaranteed) - flag possibly-truncated, never silent.
            $reason = 'MaxPerDay?'
        }

        # Dedup this day against the per-type seen-set (ReturnLargeSet is unsorted and can repeat
        # within a session; a per-type set also guards the rare day-boundary overlap).
        $dayUnique = [System.Collections.Generic.List[object]]::new()
        foreach ($r in $dayRaw) { if ($seenIds.Add("$($r.Identity)")) { $dayUnique.Add($r) } }
        $dayRows = @($dayUnique | ForEach-Object { Expand-AuditRow $_ $rt })
        $kept    = $dayRows.Count
        $skipped = $dayUnique.Count - $kept                          # dropped by the AuditData parse guard (S1)
        $dayRows | ForEach-Object { $keptRows.Add($_) }
        $dayRaw  | ForEach-Object { $allRaw.Add($_) }

        if ($reason -ne 'none') {
            $truncCount++
            Write-Warning "  $rt $($winStart.ToString('yyyy-MM-dd')): TRUNCATED ($reason) - retrieved $retrieved of $resultCount available for this day."
        }
        $summary.Add([pscustomobject]@{
            RecordType       = $rt
            Day              = $winStart.ToString('yyyy-MM-dd')
            Status           = $(if ($dayError) { 'Failed' } else { 'Success' })
            Retrieved        = $retrieved
            Kept             = $kept
            Skipped          = $skipped
            Truncated        = ($reason -ne 'none')
            TruncationReason = $reason
            Error            = $(if ($dayError) { $dayError } else { '' })
        })
        $typeKept  += $kept; $typeSkipped  += $skipped
        $totalKept += $kept; $totalSkipped += $skipped
        $day = $day.AddDays(1)
    }

    if ($keptRows.Count) { $keptRows | Export-Csv (Join-Path $outDir "$rt.csv") -NoTypeInformation -Encoding utf8 }
    if ($allRaw.Count)   { $allRaw | ConvertTo-Json -Depth 8 | Out-File (Join-Path $outDir "$rt.raw.json") -Encoding utf8 }
    if ($typeKept -or $typeSkipped) {
        $skipNote = if ($typeSkipped) { " ($typeSkipped skipped - unparseable AuditData)" } else { '' }
        Write-Host "  $rt : $typeKept records$skipNote." -ForegroundColor Green
    } else { Write-Host "  $rt : 0 records." -ForegroundColor DarkGray }
}
$summary | Export-Csv (Join-Path $outDir '_AuditSampleSummary.csv') -NoTypeInformation -Encoding utf8
Write-Host "Saved: $outDir" -ForegroundColor Cyan
$truncNote = if ($truncCount) { "$truncCount day/type slice(s) TRUNCATED - see _AuditSampleSummary.csv" } else { 'no slices truncated' }
Write-Host "Totals: $totalKept kept, $totalSkipped skipped (unparseable AuditData); $truncNote." -ForegroundColor Cyan
