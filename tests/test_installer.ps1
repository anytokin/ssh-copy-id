<#
Run with Windows PowerShell 5.1; Pester is not required:
    powershell -NoProfile -ExecutionPolicy Bypass -File tests/test_installer.ps1

The installer runs in temporary directories with mocked network commands.
AST substitutions intercept executable launches and user PATH access, so this
test never downloads a release, executes a downloaded binary, or changes PATH.
#>

$ErrorActionPreference = 'Stop'
$script:passed = 0
$script:failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$Message (expected '$Expected', got '$Actual')"
    }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Test)
    try {
        & $Test
        $script:passed++
        Write-Host "PASS: $Name"
    }
    catch {
        $script:failed++
        Write-Host "FAIL: $Name - $($_.Exception.Message)" -ForegroundColor Red
    }
}

$installerPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'install.ps1'
$tokens = $null
$parseErrors = $null
$installerAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $installerPath, [ref]$tokens, [ref]$parseErrors
)

Invoke-Test 'installer parses under Windows PowerShell' {
    Assert-Equal 0 @($parseErrors).Count (($parseErrors | Out-String).Trim())
}
if (@($parseErrors).Count -ne 0) {
    exit 1
}

$installerSource = [IO.File]::ReadAllText($installerPath)
$helperDefinitions = @($installerAst.EndBlock.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.FunctionDefinitionAst]
})
$helperSource = ($helperDefinitions | ForEach-Object { $_.Extent.Text }) -join "`r`n"
$script:versionHelpers = [scriptblock]::Create($helperSource)

# Replace only external effects that cannot be safely mocked as commands.
# Keeping the surrounding source intact also exercises the real control flow.
$environmentCalls = @($installerAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Static -and
        $node.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
        $node.Expression.TypeName.FullName -eq 'Environment' -and
        $node.Member.Value -in @('GetEnvironmentVariable', 'SetEnvironmentVariable')
}, $true))
$executableCalls = @($installerAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and
        $node.CommandElements[0].Extent.Text -eq '$LocalExePath'
}, $true))

# Fail closed if the installer changes: unrecognized effects must never run.
Assert-Equal 2 $environmentCalls.Count 'Expected both user PATH operations to be intercepted'
Assert-Equal 1 $executableCalls.Count 'Expected the local executable launch to be intercepted'
$replacements = @(
    foreach ($call in $environmentCalls) {
        $replacement = if ($call.Member.Value -eq 'GetEnvironmentVariable') {
            '(Get-TestUserPath)'
        }
        else {
            '(Set-TestUserPath -Value $newPath)'
        }
        [pscustomobject]@{ Extent = $call.Extent; Text = $replacement }
    }
    [pscustomobject]@{
        Extent = $executableCalls[0].Extent
        Text = 'Invoke-TestLocalExecutable -LocalExePath $LocalExePath'
    }
)
foreach ($replacement in ($replacements | Sort-Object { $_.Extent.StartOffset } -Descending)) {
    $installerSource = $installerSource.Remove(
        $replacement.Extent.StartOffset,
        $replacement.Extent.EndOffset - $replacement.Extent.StartOffset
    ).Insert($replacement.Extent.StartOffset, $replacement.Text)
}
$script:installerHarness = [scriptblock]::Create($installerSource)

function Invoke-InstallerScenario {
    param(
        [string]$Directory,
        [ValidateSet('Success', 'PartialFailure', 'Empty', 'Missing')]
        [string]$DownloadMode = 'Success',
        [string]$LatestTag = 'v1.2.3',
        [string]$InitialUserPath = 'C:\existing-tools',
        [string]$ExternalExePath,
        [switch]$NoModifyPath
    )

    $scenarioState = @{
        DownloadMode = $DownloadMode
        LatestTag = $LatestTag
        ApiCalls = 0
        Downloads = @()
        ExecutedPaths = @()
        PathLookups = 0
        PathReads = 0
        PathWrites = 0
        UserPath = $InitialUserPath
        ExternalExePath = $ExternalExePath
    }

    function Invoke-RestMethod {
        param($Uri, $Headers)
        $scenarioState.ApiCalls++
        return @{ tag_name = $scenarioState.LatestTag }
    }

    function Invoke-WebRequest {
        param($Uri, $OutFile, [switch]$UseBasicParsing)
        $scenarioState.Downloads += $OutFile
        switch ($scenarioState.DownloadMode) {
            'PartialFailure' {
                [IO.File]::WriteAllText($OutFile, 'partial download')
                throw 'Simulated interrupted download'
            }
            'Empty' { [IO.File]::WriteAllText($OutFile, '') }
            'Missing' { }
            'Success' { [IO.File]::WriteAllText($OutFile, 'ssh-copy-id 1.2.3') }
        }
    }

    function Invoke-TestLocalExecutable {
        param([string]$LocalExePath)
        $scenarioState.ExecutedPaths += $LocalExePath
        return [IO.File]::ReadAllText($LocalExePath)
    }

    function Get-Command {
        param([string]$Name, $ErrorAction)
        $scenarioState.PathLookups++
        if ($scenarioState.ExternalExePath) {
            return [pscustomobject]@{
                Source = $scenarioState.ExternalExePath
                Path = $scenarioState.ExternalExePath
            }
        }
    }

    function Get-TestUserPath {
        $scenarioState.PathReads++
        return $scenarioState.UserPath
    }

    function Set-TestUserPath {
        param([string]$Value)
        $scenarioState.PathWrites++
        $scenarioState.UserPath = $Value
    }

    $failure = $null
    try {
        & $script:installerHarness -InstallDir $Directory -NoModifyPath:$NoModifyPath *> $null
    }
    catch {
        $failure = $_
    }
    return [pscustomobject]@{ State = $scenarioState; Error = $failure }
}

function New-InstalledFixture {
    param([string]$Name, [string]$Version = '1.0.0')
    $directory = Join-Path $testRoot $Name
    New-Item -ItemType Directory -Path $directory | Out-Null
    [IO.File]::WriteAllText((Join-Path $directory 'ssh-copy-id.exe'), "ssh-copy-id $Version")
    return $directory
}

function Assert-OnlyInstalledExecutable {
    param([string]$Directory)
    $files = @(Get-ChildItem -LiteralPath $Directory -Force)
    Assert-Equal 1 $files.Count 'The installer left a temporary download behind'
    Assert-Equal 'ssh-copy-id.exe' $files[0].Name 'Unexpected installation artifact'
}

$testRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) (
    'ssh-copy-id-installer-tests-' + [guid]::NewGuid().ToString('N')
)))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    Invoke-Test 'GitHub version detection handles prefixes and release suffixes' {
        . $script:versionHelpers
        function Invoke-RestMethod {
            param($Uri, $Headers)
            return @{ tag_name = $tag }
        }
        foreach ($tag in @('v1.2.3', '1.2.3', ' v1.2.3-rc.1 ')) {
            Assert-Equal ([version]'1.2.3') (Get-LatestGithubVersion -ApiUrl 'https://test.invalid') (
                "Incorrect version for tag '$tag'"
            )
        }
        foreach ($tag in @('', 'not-a-version')) {
            $version = Get-LatestGithubVersion -ApiUrl 'https://test.invalid' 3>$null
            Assert-True ($null -eq $version) 'Invalid tags must not prevent installation'
        }
    }

    Invoke-Test 'GitHub API failure leaves version unknown' {
        . $script:versionHelpers
        function Invoke-RestMethod { throw 'Simulated API failure' }
        $version = Get-LatestGithubVersion -ApiUrl 'https://test.invalid' 3>$null
        Assert-True ($null -eq $version) 'An unavailable API should return an unknown version'
    }

    Invoke-Test 'installed version is read from the supplied local executable' {
        . $script:versionHelpers
        $commandPath = Join-Path $testRoot 'version.cmd'
        [IO.File]::WriteAllText($commandPath, "@echo off`r`necho ssh-copy-id 2.3.4`r`n")
        Assert-Equal ([version]'2.3.4') (Get-InstalledSshCopyIdVersion -LocalExePath $commandPath) (
            'The installed version was not parsed from command output'
        )
        [IO.File]::WriteAllText($commandPath, "@echo off`r`necho unavailable`r`n")
        $version = Get-InstalledSshCopyIdVersion -LocalExePath $commandPath
        Assert-True ($null -eq $version) 'Unrecognized executable output must return an unknown version'
        $version = Get-InstalledSshCopyIdVersion -LocalExePath (Join-Path $testRoot 'missing.exe')
        Assert-True ($null -eq $version) 'A missing local executable must return an unknown version'
    }

    foreach ($mode in @('PartialFailure', 'Empty', 'Missing')) {
        Invoke-Test "$mode download preserves the installed executable and cleans up" {
            $directory = New-InstalledFixture -Name $mode
            $exePath = Join-Path $directory 'ssh-copy-id.exe'
            $previous = [IO.File]::ReadAllBytes($exePath)
            $result = Invoke-InstallerScenario -Directory $directory -DownloadMode $mode -NoModifyPath
            Assert-True ($null -ne $result.Error) 'The installer must report a failed download'
            Assert-True ($result.Error.Exception.Message -like 'Failed to download ssh-copy-id*') (
                'The failure should include download context'
            )
            Assert-Equal ([Convert]::ToBase64String($previous)) (
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($exePath))
            ) 'A failed update changed the previously installed executable'
            Assert-Equal 1 $result.State.Downloads.Count 'Expected exactly one download attempt'
            Assert-OnlyInstalledExecutable -Directory $directory
        }
    }

    Invoke-Test 'successful update replaces the executable and removes its temporary file' {
        $directory = New-InstalledFixture -Name 'successful-update'
        $exePath = Join-Path $directory 'ssh-copy-id.exe'
        $result = Invoke-InstallerScenario -Directory $directory -NoModifyPath
        Assert-True ($null -eq $result.Error) "Update failed: $($result.Error)"
        Assert-Equal 'ssh-copy-id 1.2.3' ([IO.File]::ReadAllText($exePath)) 'Update was not installed'
        Assert-Equal 1 $result.State.Downloads.Count 'Expected exactly one download'
        Assert-True ($result.State.Downloads[0] -ne $exePath) 'Download must use a temporary file'
        Assert-Equal 0 $result.State.PathReads 'NoModifyPath must skip reading user PATH'
        Assert-Equal 0 $result.State.PathWrites 'NoModifyPath must skip changing user PATH'
        Assert-OnlyInstalledExecutable -Directory $directory
    }

    Invoke-Test 'a current executable elsewhere on PATH does not skip a custom installation' {
        $externalDirectory = New-InstalledFixture -Name 'external-copy' -Version '1.2.3'
        $directory = Join-Path $testRoot 'custom-missing-directory'
        $result = Invoke-InstallerScenario -Directory $directory -ExternalExePath (
            Join-Path $externalDirectory 'ssh-copy-id.exe'
        ) -NoModifyPath
        Assert-True ($null -eq $result.Error) "Custom installation failed: $($result.Error)"
        Assert-Equal 1 $result.State.Downloads.Count 'The requested directory still needs installation'
        Assert-Equal 0 $result.State.PathLookups 'Version detection must use the requested local copy'
        Assert-Equal 'ssh-copy-id 1.2.3' (
            [IO.File]::ReadAllText((Join-Path $directory 'ssh-copy-id.exe'))
        ) 'The custom directory was not populated'
        Assert-OnlyInstalledExecutable -Directory $directory
    }

    Invoke-Test 'an already current local version still adds its directory to user PATH' {
        $directory = New-InstalledFixture -Name 'already-current' -Version '1.2.3'
        $result = Invoke-InstallerScenario -Directory $directory
        Assert-True ($null -eq $result.Error) "Current-version check failed: $($result.Error)"
        Assert-Equal 0 $result.State.Downloads.Count 'A current version must not be downloaded again'
        Assert-Equal 1 $result.State.PathReads 'The PATH step was skipped for a current version'
        Assert-Equal 1 $result.State.PathWrites 'The install directory was not added to user PATH'
        Assert-Equal "$directory;C:\existing-tools" $result.State.UserPath 'Existing PATH entries were lost'
        Assert-OnlyInstalledExecutable -Directory $directory
    }

    Invoke-Test 'an existing PATH entry is not duplicated' {
        $directory = New-InstalledFixture -Name 'already-on-path' -Version '1.2.3'
        $userPath = "C:\existing-tools;$directory"
        $result = Invoke-InstallerScenario -Directory $directory -InitialUserPath $userPath
        Assert-True ($null -eq $result.Error) "PATH check failed: $($result.Error)"
        Assert-Equal 1 $result.State.PathReads 'The existing PATH must be checked'
        Assert-Equal 0 $result.State.PathWrites 'An existing install directory must not be added again'
        Assert-Equal $userPath $result.State.UserPath 'An existing PATH entry was changed'
    }

    Invoke-Test 'a relative install directory becomes an absolute PATH entry' {
        $directory = Join-Path $testRoot 'relative-install'
        Push-Location -LiteralPath $testRoot
        try {
            $result = Invoke-InstallerScenario -Directory '.\relative-install'
        }
        finally {
            Pop-Location
        }
        Assert-True ($null -eq $result.Error) "Relative installation failed: $($result.Error)"
        Assert-Equal "$directory;C:\existing-tools" $result.State.UserPath (
            'The installer persisted a relative directory in user PATH'
        )
        Assert-Equal 1 $result.State.Downloads.Count 'The relative directory still needs installation'
        Assert-Equal $directory ([IO.Path]::GetDirectoryName($result.State.Downloads[0])) (
            'The download target was not resolved against the working directory'
        )
        Assert-OnlyInstalledExecutable -Directory $directory
    }
}
finally {
    # Verify the resolved target before recursively removing the test fixture.
    $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).ProviderPath
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if ($resolvedTestRoot -ne $testRoot -or
        (Split-Path $resolvedTestRoot -Parent) -ne $expectedParent) {
        throw "Refusing to clean an unexpected test directory: $resolvedTestRoot"
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}

Write-Host "$script:passed passed; $script:failed failed."
if ($script:failed -ne 0) {
    exit 1
}
