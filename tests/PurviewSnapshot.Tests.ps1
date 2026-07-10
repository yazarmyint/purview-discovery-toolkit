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
