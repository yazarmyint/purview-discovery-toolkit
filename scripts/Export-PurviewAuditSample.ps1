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
    SessionId. For full, durable evidence forward UAL to SIEM (Sentinel) - this is a sample.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceUpn,
    [string]$OutputRoot = "C:\PurviewDiscovery",
    [int]$DaysBack = 30,
    [string[]]$RecordTypes = @('ComplianceDLPSharePoint','ComplianceDLPExchange','DLPEndpoint',
                               'SensitivityLabelAction','SensitivityLabeledFileAction','MIPLabel','MultiStageDisposition'),
    [int]$MaxPerType = 50000,
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
    $d = $rec.AuditData | ConvertFrom-Json
    $isDlp = ($rt -like 'ComplianceDLP*') -or ($rt -eq 'DLPEndpoint')
    $policy = ''; $sit = ''
    if ($isDlp) {
        # PolicyDetails[].Rules[].ConditionsMatched.SensitiveInformation[].SensitiveInformationTypeName
        $policy = ($d.PolicyDetails.PolicyName -join ';')
        $sit    = ($d.PolicyDetails.Rules.ConditionsMatched.SensitiveInformation.SensitiveInformationTypeName -join ';')
    }
    [pscustomobject]@{
        CreationDate = $rec.CreationDate
        RecordType   = $(if ($rec.RecordType) { $rec.RecordType } else { $rt })   # -Formatted gives a string; fall back to the queried type
        Operation    = $d.Operation; UserId = $d.UserId
        Workload     = $d.Workload;  ObjectId = $d.ObjectId
        PolicyName   = $policy; SitName = $sit
        RawAuditData = $rec.AuditData
    }
}

foreach ($rt in $RecordTypes) {
    Write-Host "Searching record type: $rt ..." -ForegroundColor Yellow
    $all = [System.Collections.Generic.List[object]]::new()
    # Segment per-day with a fresh SessionId so any single day can return up to 50,000 records.
    $day = $startUtc
    while ($day -lt $endUtc -and $all.Count -lt $MaxPerType) {
        $winStart = $day
        $winEnd   = $day.AddDays(1); if ($winEnd -gt $endUtc) { $winEnd = $endUtc }
        $sid = [guid]::NewGuid().ToString()
        try {
            do {
                $page = Search-UnifiedAuditLog -StartDate $winStart -EndDate $winEnd -RecordType $rt -Formatted `
                            -SessionId $sid -SessionCommand ReturnLargeSet -ResultSize 5000
                if ($page) { $page | ForEach-Object { $all.Add($_) } }
            # Reliable termination: loop until a page returns zero records (or we hit the cap).
            } while ($page -and @($page).Count -gt 0 -and $all.Count -lt $MaxPerType)
        } catch {
            Write-Warning "  $rt $($winStart.ToString('yyyy-MM-dd')) failed: $($_.Exception.Message)"
        }
        $day = $day.AddDays(1)
    }

    if ($all.Count) {
        $rows = $all | Sort-Object Identity -Unique | ForEach-Object { Expand-AuditRow $_ $rt }   # dedupe (ReturnLargeSet is unsorted)
        $rows | Export-Csv (Join-Path $outDir "$rt.csv") -NoTypeInformation -Encoding utf8
        $all  | ConvertTo-Json -Depth 8 | Out-File (Join-Path $outDir "$rt.raw.json") -Encoding utf8
        Write-Host "  $rt : $($rows.Count) records." -ForegroundColor Green
    } else { Write-Host "  $rt : 0 records." -ForegroundColor DarkGray }
}
Write-Host "Saved: $outDir" -ForegroundColor Cyan
