# Pester v5 unit tests for scripts/PurviewSnapshot.psm1 - the shared snapshot plumbing.
# Fully offline: no tenant cmdlets exist in this session; collect blocks are fakes.

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:ModulePath = Join-Path (Join-Path $repoRoot 'scripts') 'PurviewSnapshot.psm1'
    Import-Module $script:ModulePath -Force
}

Describe 'Resolve-SnapshotFailureStatus (D9 classifier)' {
    It 'maps a missing command to CmdletNotAvailable' {
        $ex = $null
        try { NoSuchCmdlet-Abc123XYZ } catch { $ex = $_.Exception }
        Resolve-SnapshotFailureStatus -Exception $ex | Should -Be 'CmdletNotAvailable'
    }
    It 'maps UnauthorizedAccessException to AccessDenied' {
        $ex = New-Object System.UnauthorizedAccessException 'nope'
        Resolve-SnapshotFailureStatus -Exception $ex | Should -Be 'AccessDenied'
    }
    It 'maps access-denied message text to AccessDenied' {
        $ex = New-Object System.InvalidOperationException 'Access is denied. Check role assignments.'
        Resolve-SnapshotFailureStatus -Exception $ex | Should -Be 'AccessDenied'
    }
    It 'maps unauthorized / forbidden / insufficient-permission signals to AccessDenied' {
        Resolve-SnapshotFailureStatus -Exception (New-Object System.Exception 'The remote server returned an error: (403) Forbidden.') | Should -Be 'AccessDenied'
        Resolve-SnapshotFailureStatus -Exception (New-Object System.Exception 'Unauthorized') | Should -Be 'AccessDenied'
        Resolve-SnapshotFailureStatus -Exception (New-Object System.Exception 'insufficient permissions to perform this operation') | Should -Be 'AccessDenied'
    }
    It 'finds an authz signal buried in an inner exception' {
        $inner = New-Object System.Exception 'Access denied by RBAC'
        $ex = New-Object -TypeName System.Exception -ArgumentList @('outer wrapper', $inner)
        Resolve-SnapshotFailureStatus -Exception $ex | Should -Be 'AccessDenied'
    }
    It 'maps anything else to Failed' {
        Resolve-SnapshotFailureStatus -Exception (New-Object System.Exception 'The network path was not found') | Should -Be 'Failed'
    }
}

Describe 'Get-SnapshotArea (envelope + status paths)' {
    It 'Success: objects collected and counted, envelope carries area identity and cmdlets' {
        $env = Get-SnapshotArea -Area 'Test.Area' -Cmdlet 'Get-Fake' -Collect {
            @([pscustomobject]@{ Guid = 'b'; Name = 'B' }, [pscustomobject]@{ Guid = 'a'; Name = 'A' })
        }
        $env.area   | Should -Be 'Test.Area'
        @($env.cmdlets) | Should -Be @('Get-Fake')
        $env.status | Should -Be 'Success'
        $env.count  | Should -Be 2
        $env.error  | Should -BeNullOrEmpty
        $env.durationMs | Should -BeGreaterOrEqual 0
        $env.diffExcluded | Should -BeFalse
    }
    It 'orders objects deterministically by stable key regardless of input order' {
        $ab = Get-SnapshotArea -Area 'T' -Collect { @([pscustomobject]@{ Guid = 'a' }, [pscustomobject]@{ Guid = 'b' }) }
        $ba = Get-SnapshotArea -Area 'T' -Collect { @([pscustomobject]@{ Guid = 'b' }, [pscustomobject]@{ Guid = 'a' }) }
        @($ab.objects)[0].Guid | Should -Be 'a'
        @($ba.objects)[0].Guid | Should -Be 'a'
    }
    It 'orders duplicate stable keys deterministically by content' {
        $r1 = Get-SnapshotArea -Area 'T' -Collect { @([pscustomobject]@{ Name = 'same'; Payload = 'zzz' }, [pscustomobject]@{ Name = 'same'; Payload = 'aaa' }) }
        $r2 = Get-SnapshotArea -Area 'T' -Collect { @([pscustomobject]@{ Name = 'same'; Payload = 'aaa' }, [pscustomobject]@{ Name = 'same'; Payload = 'zzz' }) }
        @($r1.objects)[0].Payload | Should -Be @($r2.objects)[0].Payload
    }
    It 'Empty: zero objects still emit a full envelope with an array objects field' {
        $env = Get-SnapshotArea -Area 'T' -Cmdlet 'Get-Fake' -Collect { @() }
        $env.status | Should -Be 'Empty'
        $env.count  | Should -Be 0
        $env.objects.GetType().IsArray | Should -BeTrue
    }
    It 'CmdletNotAvailable: a missing cmdlet inside the collect block' {
        $env = Get-SnapshotArea -Area 'T' -Cmdlet 'No-SuchThing' -Collect { NoSuchCmdlet-Abc123XYZ }
        $env.status | Should -Be 'CmdletNotAvailable'
        $env.count  | Should -Be 0
        $env.error  | Should -Not -BeNullOrEmpty
    }
    It 'AccessDenied: an authorization failure is distinguished from Failed' {
        $env = Get-SnapshotArea -Area 'T' -Collect { throw 'Access is denied.' }
        $env.status | Should -Be 'AccessDenied'
    }
    It 'Failed: any other failure, message recorded' {
        $env = Get-SnapshotArea -Area 'T' -Collect { throw 'kaboom' }
        $env.status | Should -Be 'Failed'
        $env.error  | Should -Match 'kaboom'
    }
    It 'NotAttempted: -Skip short-circuits with the reason recorded and no collect call' {
        $script:CollectRan = $false
        $env = Get-SnapshotArea -Area 'T' -Skip -SkipReason 'switch not set' -Collect { $script:CollectRan = $true }
        $env.status | Should -Be 'NotAttempted'
        $env.error  | Should -Be 'switch not set'
        $script:CollectRan | Should -BeFalse
    }
    It 'Process: transforms objects, attaches sidecars, notes surface in error' {
        $env = Get-SnapshotArea -Area 'T' -Collect { @([pscustomobject]@{ Name = 'p1' }) } -Process {
            param($objs)
            @{ Objects  = @([pscustomobject]@{ Name = 'desc1'; SidecarPath = 'sidecars/T/p1.xml' })
               Sidecars = @([pscustomobject]@{ name = 'p1.xml'; path = 'sidecars/T/p1.xml'; diffExcluded = $false })
               Notes    = @('p2: unreadable') }
        }
        $env.status | Should -Be 'Success'
        $env.count  | Should -Be 1
        @($env.sidecars).Count | Should -Be 1
        $env.error  | Should -Match 'unreadable'
    }
    It 'Process failures classify into the envelope status' {
        $env = Get-SnapshotArea -Area 'T' -Collect { @(1) } -Process { throw 'Access denied writing sidecar' }
        $env.status | Should -Be 'AccessDenied'
    }
    # Sandbox defect (Task 5b): EXO v3 cmdlets are proxy functions in their own
    # module session state, where the calling script's ErrorActionPreference='Stop'
    # does not apply. A REST failure there is written as a NON-terminating error:
    # the collect block returns nothing and the area recorded [Empty] - an error
    # masquerading as valid negative evidence. Non-terminating errors must classify
    # through the same status vocabulary as thrown exceptions.
    It 'a non-terminating error from the collect block records Failed, never Empty' {
        $env = Get-SnapshotArea -Area 'T' -Cmdlet 'Get-Fake' -Collect {
            $ErrorActionPreference = 'Continue'
            Write-Error 'The operation is only allowed to run in Exchange Online Protection environment.'
        }
        $env.status | Should -Be 'Failed'
        $env.count  | Should -Be 0
        $env.error  | Should -Match 'Exchange Online Protection'
    }
    It 'a non-terminating authorization error classifies AccessDenied' {
        $env = Get-SnapshotArea -Area 'T' -Collect {
            $ErrorActionPreference = 'Continue'
            Write-Error 'Access is denied. Check role assignments.'
        }
        $env.status | Should -Be 'AccessDenied'
    }
    It 'partial output plus a non-terminating error keeps the objects but records the failure status' {
        $env = Get-SnapshotArea -Area 'T' -Collect {
            $ErrorActionPreference = 'Continue'
            [pscustomobject]@{ Name = 'n1' }
            Write-Error 'stream broke midway'
        }
        $env.status | Should -Be 'Failed'
        $env.count  | Should -Be 1
        @($env.objects)[0].Name | Should -Be 'n1'
        $env.error  | Should -Match 'stream broke'
    }
    It 'strips PowerShell remoting noise properties from objects' {
        $env = Get-SnapshotArea -Area 'T' -Collect {
            @([pscustomobject]@{ Name = 'x'; PSComputerName = 'srv'; RunspaceId = 'r'; PSShowComputerName = $true })
        }
        $names = @(@($env.objects)[0].PSObject.Properties | ForEach-Object { $_.Name })
        $names | Should -Not -Contain 'PSComputerName'
        $names | Should -Not -Contain 'RunspaceId'
        $names | Should -Not -Contain 'PSShowComputerName'
        $names | Should -Contain 'Name'
    }
}

Describe 'Stable-key property overrides (Task 5c)' {
    # Rule objects may lack a Guid on live output (prior-audit suspect). Each rule
    # area declares a documented composite key so the future diff never silently
    # falls back to the content hash; the envelope carries the declaration so
    # snapshots are self-describing.
    It 'orders by the declared composite key, policy before name' {
        $env = Get-SnapshotArea -Area 'T' -StableKeyProperty @('ParentPolicyName', 'Name') -Collect {
            @([pscustomobject]@{ Name = 'zz'; ParentPolicyName = 'A-Pol' },
              [pscustomobject]@{ Name = 'aa'; ParentPolicyName = 'B-Pol' },
              [pscustomobject]@{ Name = 'bb'; ParentPolicyName = 'A-Pol' })
        }
        @($env.objects | ForEach-Object { $_.Name }) | Should -Be @('bb', 'zz', 'aa')
    }
    It 'the envelope declares its stable-key properties (self-describing for the diff)' {
        $env = Get-SnapshotArea -Area 'T' -StableKeyProperty @('Guid', 'ParentPolicyName', 'Name') -Collect { @() }
        @($env.stableKeyProperties) | Should -Be @('Guid', 'ParentPolicyName', 'Name')
        $env2 = Get-SnapshotArea -Area 'T2' -Collect { @() }
        @($env2.stableKeyProperties).Count | Should -Be 0
    }
    It 'objects missing every declared key property fall back to the generic stable key' {
        $env = Get-SnapshotArea -Area 'T' -StableKeyProperty @('Guid', 'ParentPolicyName') -Collect {
            @([pscustomobject]@{ Identity = 'z' }, [pscustomobject]@{ Identity = 'a' })
        }
        @($env.objects | ForEach-Object { $_.Identity }) | Should -Be @('a', 'z')
    }
}

Describe 'Get-SnapshotStableKey' {
    It 'prefers Guid (composited with Name), then Name, then Identity' {
        Get-SnapshotStableKey ([pscustomobject]@{ Guid = 'g1'; Name = 'n'; Identity = 'i' }) | Should -Be 'guid:g1|name:n'
        Get-SnapshotStableKey ([pscustomobject]@{ Name = 'n'; Identity = 'i' }) | Should -Be 'name:n'
        Get-SnapshotStableKey ([pscustomobject]@{ Identity = 'i' }) | Should -Be 'id:i'
    }
    It 'falls back to a deterministic content hash when no identifier exists' {
        $k1 = Get-SnapshotStableKey ([pscustomobject]@{ Foo = 'bar' })
        $k2 = Get-SnapshotStableKey ([pscustomobject]@{ Foo = 'bar' })
        $k1 | Should -Be $k2
        $k1 | Should -Match '^hash:[0-9a-f]{64}$'
    }
}

Describe 'Dictionary-valued properties (serialization guard, Task 5a)' {
    # Sandbox defect: Get-DlpSensitiveInformationType objects carry a Hashtable
    # property whose keys are not strings; Windows PowerShell 5.1's ConvertTo-Json
    # rejects it ("Keys must be strings"), failing the whole area. pwsh 7 serializes
    # such keys but in randomized hash order, breaking byte-identical diffs. The
    # normalization layer must make every dictionary JSON-safe AND deterministic.
    BeforeAll {
        function New-GuardProvenance {
            $t0 = New-Object datetime 2026, 7, 12, 12, 0, 0, ([System.DateTimeKind]::Utc)
            Get-SnapshotProvenance -UserPrincipalName 'op@contoso.example' -Parameters @{} `
                -StartedUtc $t0 -EndedUtc $t0 -ScriptName 'Test.ps1'
        }
    }
    It 'an area whose objects carry non-string-keyed dictionary properties records Success, not Failed' {
        $env = Get-SnapshotArea -Area 'T.Sits' -Collect {
            $h1 = @{}; $h1[[int]1] = 'one'
            $h2 = @{}; $h2[[int]2] = 'two'
            @([pscustomobject]@{ Name = 'SIT-B'; Map = $h1 },
              [pscustomobject]@{ Name = 'SIT-A'; Map = $h2 })
        }
        $env.status | Should -Be 'Success'
        $env.count  | Should -Be 2
    }
    It 'non-string dictionary keys serialize losslessly with stringified keys' {
        $env = Get-SnapshotArea -Area 'T.One' -Collect {
            $h = @{}; $h[[int]1] = 'one'
            ,([pscustomobject]@{ Name = 'only'; Map = $h })
        }
        $doc = Get-PurviewSnapshotDocument -Provenance (New-GuardProvenance) -Areas @($env)
        $json = ConvertTo-CanonicalSnapshotJson -Document $doc
        $json | Should -Match '"1":\s*"one"'
    }
    It 'dictionary properties serialize with ordinally sorted keys on every engine' {
        $env = Get-SnapshotArea -Area 'T.Sorted' -Collect {
            ,([pscustomobject]@{
                Name = 'x'
                Map  = @{ kh = 'v'; ka = 'v'; kf = 'v'; kc = 'v'; ke = 'v'; kb = 'v'; kg = 'v'; kd = 'v' }
            })
        }
        $doc = Get-PurviewSnapshotDocument -Provenance (New-GuardProvenance) -Areas @($env)
        $json = ConvertTo-CanonicalSnapshotJson -Document $doc
        $idx = @('ka', 'kb', 'kc', 'kd', 'ke', 'kf', 'kg', 'kh' | ForEach-Object { $json.IndexOf('"' + $_ + '"') })
        $idx[0] | Should -BeGreaterThan -1
        for ($i = 1; $i -lt $idx.Count; $i++) { $idx[$i] | Should -BeGreaterThan $idx[$i - 1] }
    }
    It 'dictionaries nested inside arrays and child objects are normalized too' {
        $env = Get-SnapshotArea -Area 'T.Nested' -Collect {
            $inner = @{}; $inner[[int]5] = 'five'
            ,([pscustomobject]@{
                Name  = 'x'
                List  = @(, $inner)
                Child = [pscustomobject]@{ DeepMap = $inner }
            })
        }
        $doc = Get-PurviewSnapshotDocument -Provenance (New-GuardProvenance) -Areas @($env)
        $json = ConvertTo-CanonicalSnapshotJson -Document $doc
        ([regex]::Matches($json, '"5":\s*"five"')).Count | Should -Be 2
    }
    It 'stringified key collisions remain lossless (disambiguated, both values kept)' {
        $env = Get-SnapshotArea -Area 'T.Collide' -Collect {
            $h = @{}; $h[[int]1] = 'intval'; $h['1'] = 'strval'
            ,([pscustomobject]@{ Name = 'x'; Map = $h })
        }
        $doc = Get-PurviewSnapshotDocument -Provenance (New-GuardProvenance) -Areas @($env)
        $json = ConvertTo-CanonicalSnapshotJson -Document $doc
        $json | Should -Match '"1#2":'
        $json | Should -Match '"intval"'
        $json | Should -Match '"strval"'
    }
    It 'passes scalars, strings, dates and enums through unchanged' {
        $d = Get-Date
        (ConvertTo-SnapshotSafeValue -Value 'plain') | Should -BeExactly 'plain'
        (ConvertTo-SnapshotSafeValue -Value 42)      | Should -Be 42
        (ConvertTo-SnapshotSafeValue -Value $d)      | Should -BeOfType [datetime]
        (ConvertTo-SnapshotSafeValue -Value ([System.DayOfWeek]::Friday)) | Should -Be ([System.DayOfWeek]::Friday)
    }
}

Describe 'Get-SafeName' {
    It 'sanitizes path-hostile characters and blanks' {
        Get-SafeName 'a/b:c*d' | Should -Be 'a_b_c_d'
        Get-SafeName ''        | Should -Be 'unnamed'
    }
}

Describe 'Connect-PurviewSnapshotSession' {
    It 'is a no-op with -ReuseExistingSession (offline-safe)' {
        { Connect-PurviewSnapshotSession -UserPrincipalName 'x@y.example' -ReuseExistingSession } | Should -Not -Throw
    }
}

Describe 'Get-PurviewSnapshotDocument + canonical serialization (D9 diff-readiness)' {
    BeforeAll {
        function New-FixedProvenance {
            $t0 = New-Object datetime 2026, 7, 10, 12, 0, 0, ([System.DateTimeKind]::Utc)
            Get-SnapshotProvenance -UserPrincipalName 'op@contoso.example' `
                -Parameters @{ OutputRoot = 'C:\x'; ReuseExistingSession = ([switch]$true) } `
                -StartedUtc $t0 -EndedUtc ($t0.AddMinutes(5)) -ScriptName 'Test.ps1' -Outcome 'Completed'
        }
    }
    It 'document carries schemaVersion, provenance, volatile register and areas' {
        $doc = Get-PurviewSnapshotDocument -Provenance (New-FixedProvenance) -Areas @(
            (Get-SnapshotArea -Area 'T.One' -Collect { @([pscustomobject]@{ Guid = 'g'; Name = 'n' }) }))
        $doc.schemaVersion | Should -Be '1.0'
        $doc.provenance.userPrincipalName | Should -Be 'op@contoso.example'
        @($doc.volatileFields).Count | Should -BeGreaterThan 0
        @($doc.areas).Count | Should -Be 1
    }
    It 'empty and denied areas still serialize as full envelopes' {
        $areas = @(
            (Get-SnapshotArea -Area 'T.Empty' -Collect { @() }),
            (Get-SnapshotArea -Area 'T.Denied' -Collect { throw 'Access is denied.' })
        )
        $doc = Get-PurviewSnapshotDocument -Provenance (New-FixedProvenance) -Areas $areas
        $json = ConvertTo-CanonicalSnapshotJson -Document $doc
        $json | Should -Match '"T\.Empty"'
        $json | Should -Match '"T\.Denied"'
        $json | Should -Match '"AccessDenied"'
    }
    It '1-item areas serialize objects as a 1-element ARRAY; 0-item as an empty array' {
        $areas = @(
            (Get-SnapshotArea -Area 'T.Single' -Collect { ,([pscustomobject]@{ Name = 'only' }) }),
            (Get-SnapshotArea -Area 'T.None' -Collect { @() })
        )
        $doc = Get-PurviewSnapshotDocument -Provenance (New-FixedProvenance) -Areas $areas
        $json = ConvertTo-CanonicalSnapshotJson -Document $doc
        $m = [regex]::Matches($json, '"objects":\s*(\S)')
        $m.Count | Should -Be 2
        foreach ($x in $m) { $x.Groups[1].Value | Should -Be '[' }
    }
    It 'serialization is byte-identical across two writes of the same in-memory document' {
        $doc = Get-PurviewSnapshotDocument -Provenance (New-FixedProvenance) -Areas @(
            (Get-SnapshotArea -Area 'T.One' -Collect { @([pscustomobject]@{ Guid = 'b' }, [pscustomobject]@{ Guid = 'a' }) }))
        $p1 = Join-Path $TestDrive 'snap1.json'
        $p2 = Join-Path $TestDrive 'snap2.json'
        Write-PurviewSnapshot -Document $doc -Path $p1
        Write-PurviewSnapshot -Document $doc -Path $p2
        (Get-FileHash $p1).Hash | Should -Be (Get-FileHash $p2).Hash
    }
    It 'snapshot files are UTF-8 without a byte order mark' {
        $doc = Get-PurviewSnapshotDocument -Provenance (New-FixedProvenance) -Areas @()
        $p = Join-Path $TestDrive 'snap-bom.json'
        Write-PurviewSnapshot -Document $doc -Path $p
        $bytes = [System.IO.File]::ReadAllBytes($p)
        $bytes[0] | Should -Be 0x7B
    }
}

Describe 'Get-SnapshotProvenance' {
    It 'carries UPN, versions, engine, sorted typed parameters, ISO-8601 UTC timestamps, outcome' {
        $t0 = New-Object datetime 2026, 7, 10, 12, 0, 0, ([System.DateTimeKind]::Utc)
        $prov = Get-SnapshotProvenance -UserPrincipalName 'op@contoso.example' `
            -Parameters @{ Zeta = 'z'; Alpha = 1; Flag = ([switch]$true) } `
            -StartedUtc $t0 -EndedUtc ($t0.AddMinutes(1)) -ScriptName 'X.ps1' -Outcome 'Aborted'
        $prov.tool              | Should -Be 'purview-discovery-toolkit'
        $prov.toolVersion       | Should -Not -BeNullOrEmpty
        $prov.userPrincipalName | Should -Be 'op@contoso.example'
        $prov.script            | Should -Be 'X.ps1'
        $prov.outcome           | Should -Be 'Aborted'
        $prov.startedUtc | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$'
        $prov.endedUtc   | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$'
        @($prov.parameters.Keys) | Should -Be @('Alpha', 'Flag', 'Zeta')
        $prov.parameters['Flag'] | Should -BeOfType [bool]
        $prov.powerShell.edition | Should -Not -BeNullOrEmpty
    }
    It 'projects tenant identity from Get-ConnectionInformation, excluding volatile token fields' {
        function global:Get-ConnectionInformation {
            [pscustomobject]@{
                UserPrincipalName = 'op@contoso.example'
                TenantID          = '00000000-0000-0000-0000-000000000001'
                Organization      = 'contoso.example'
                State             = 'Connected'
                TokenExpiryTimeUTC = (Get-Date)
            }
        }
        try {
            $prov = Get-SnapshotProvenance -UserPrincipalName 'op@contoso.example' -Parameters @{} `
                -StartedUtc (Get-Date).ToUniversalTime() -EndedUtc (Get-Date).ToUniversalTime()
            @($prov.connections).Count | Should -Be 1
            @($prov.connections)[0].TenantID | Should -Be '00000000-0000-0000-0000-000000000001'
            @(@($prov.connections)[0].PSObject.Properties | ForEach-Object { $_.Name }) | Should -Not -Contain 'TokenExpiryTimeUTC'
        } finally {
            Remove-Item -Path 'function:Get-ConnectionInformation' -Force -ErrorAction SilentlyContinue
        }
    }
    It 'tolerates Get-ConnectionInformation being absent or unconnected (offline)' {
        $prov = Get-SnapshotProvenance -UserPrincipalName 'x@y.example' -Parameters @{} `
            -StartedUtc (Get-Date).ToUniversalTime() -EndedUtc (Get-Date).ToUniversalTime()
        @($prov.connections).Count | Should -Be 0
    }
}

Describe 'Write-SnapshotAreaCsvViews (derived views, Task 5d)' {
    # Per-area CSVs are DERIVED from snapshot envelopes - the writer only ever sees
    # collected envelopes, never a tenant. Columns frozen against documentation may
    # be absent on live objects: they emit blank (a caught-later signal), never an
    # error.
    It 'projects the registered columns in order, blank where the property is absent' {
        $env = Get-SnapshotArea -Area 'T.Labels' -Collect {
            @([pscustomobject]@{ Name = 'b'; Guid = 'g2'; DisplayName = 'B' },
              [pscustomobject]@{ Name = 'a'; Guid = 'g1'; DisplayName = 'A' })
        }
        $dir = Join-Path $TestDrive 'views1'
        $written = Write-SnapshotAreaCsvViews -Areas @($env) -Directory $dir `
            -Columns @{ 'T.Labels' = @('Name', 'Guid', 'ParentLabelDisplayName', 'Disabled') }
        @($written).Count | Should -Be 1
        $rows = @(Import-Csv (Join-Path $dir 'T.Labels.csv'))
        $rows.Count | Should -Be 2
        @($rows[0].PSObject.Properties | ForEach-Object { $_.Name }) | Should -Be @('Name', 'Guid', 'ParentLabelDisplayName', 'Disabled')
        $rows[0].Name | Should -Be 'a'
        $rows[0].ParentLabelDisplayName | Should -Be ''
        $rows[0].Disabled | Should -Be ''
    }
    It 'flattens array-valued properties into a delimited cell' {
        $env = Get-SnapshotArea -Area 'T.Pol' -Collect {
            ,([pscustomobject]@{ Name = 'p'; Labels = @('Alpha', 'Beta') })
        }
        $dir = Join-Path $TestDrive 'views2'
        Write-SnapshotAreaCsvViews -Areas @($env) -Directory $dir -Columns @{ 'T.Pol' = @('Name', 'Labels') } | Out-Null
        (Import-Csv (Join-Path $dir 'T.Pol.csv'))[0].Labels | Should -Be 'Alpha; Beta'
    }
    It 'writes views only for areas with collected objects and a registered column set' {
        $areas = @(
            (Get-SnapshotArea -Area 'T.Empty' -Collect { @() }),
            (Get-SnapshotArea -Area 'T.Failed' -Collect { throw 'kaboom' }),
            (Get-SnapshotArea -Area 'T.NoView' -Collect { ,([pscustomobject]@{ Name = 'x' }) })
        )
        $dir = Join-Path $TestDrive 'views3'
        $written = Write-SnapshotAreaCsvViews -Areas $areas -Directory $dir `
            -Columns @{ 'T.Empty' = @('Name'); 'T.Failed' = @('Name') }
        @($written).Count | Should -Be 0
        Test-Path $dir | Should -BeFalse
    }
}

Describe 'Write-SnapshotManifestCsv (status view)' {
    It 'writes one row per area with the envelope status columns' {
        $areas = @(
            (Get-SnapshotArea -Area 'T.A' -Cmdlet 'Get-X' -Collect { @() }),
            (Get-SnapshotArea -Area 'T.B' -Skip -SkipReason 'switch not set')
        )
        $p = Join-Path $TestDrive 'manifest.csv'
        Write-SnapshotManifestCsv -Areas $areas -Path $p
        $rows = @(Import-Csv $p)
        $rows.Count | Should -Be 2
        ($rows | Where-Object { $_.Area -eq 'T.A' }).Status | Should -Be 'Empty'
        ($rows | Where-Object { $_.Area -eq 'T.B' }).Status | Should -Be 'NotAttempted'
    }
}
