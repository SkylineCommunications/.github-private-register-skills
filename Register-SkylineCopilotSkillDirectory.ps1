$ErrorActionPreference = 'Stop'

# This script:
# - Sparse-checks out only the skills folder from SkylineCommunications/.github-private
# - Mirrors those skills into $HOME\.copilot\skills
# - Creates or updates a scheduled task that refreshes the skills every 3 hours
# - Updates the generated sync script every time this installer runs
# - Does not use skillDirectories or settings.json
# - Does not store credentials, tokens, or passwords
# - Requires the user to already have Git access to the private repository
# - Supports Windows PowerShell 5.1 and PowerShell 7+
# - Rotates its sync.log file to avoid infinite log growth
# - Uses a hidden VBScript launcher for scheduled runs to avoid PowerShell windows popping up

$syncRoot = Join-Path $HOME '.copilot\skyline-skills-sync'
$syncScriptPath = Join-Path $syncRoot 'Sync-SkylineCopilotSkills.ps1'
$launcherScriptPath = Join-Path $syncRoot 'Run-SkylineCopilotSkillsSyncHidden.vbs'
$taskName = 'Skyline Copilot Skills Sync'

function Invoke-SkylineNativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = 'Continue'

        & $FilePath @Arguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw "Command failed with exit code $exitCode`: $FilePath $($Arguments -join ' ')"
    }
}

New-Item -Path $syncRoot -ItemType Directory -Force | Out-Null

$syncScript = @'
$ErrorActionPreference = 'Stop'

$repoUrl = 'https://github.com/SkylineCommunications/.github-private.git'
$branch = 'main'

$syncRoot = Join-Path $HOME '.copilot\skyline-skills-sync'
$repoDir = Join-Path $syncRoot 'repo'
$sourceSkillsDir = Join-Path $repoDir 'skills'
$destinationSkillsDir = Join-Path $HOME '.copilot\skills'
$installedSkillsFile = Join-Path $syncRoot 'installed-skills.txt'
$logFile = Join-Path $syncRoot 'sync.log'

function Write-SyncLog {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    $maxLogSizeBytes = 256KB
    $maxArchivedLogs = 5

    if (Test-Path $logFile) {
        $logItem = Get-Item -Path $logFile

        if ($logItem.Length -ge $maxLogSizeBytes) {
            for ($i = $maxArchivedLogs - 1; $i -ge 1; $i--) {
                $currentArchive = "$logFile.$i"
                $nextArchive = "$logFile.$($i + 1)"

                if (Test-Path $currentArchive) {
                    if (Test-Path $nextArchive) {
                        Remove-Item -Path $nextArchive -Force
                    }

                    Move-Item -Path $currentArchive -Destination $nextArchive -Force
                }
            }

            $firstArchive = "$logFile.1"

            if (Test-Path $firstArchive) {
                Remove-Item -Path $firstArchive -Force
            }

            Move-Item -Path $logFile -Destination $firstArchive -Force
        }
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logFile -Value "[$timestamp] $Message"
}

function Invoke-SkylineNativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    # Native tools like git can write normal output to stderr.
    # With $ErrorActionPreference = 'Stop', PowerShell can treat that as a NativeCommandError.
    # Use Continue temporarily and rely on the native exit code instead.
    $previousErrorActionPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = 'Continue'

        & $FilePath @Arguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw "Command failed with exit code $exitCode`: $FilePath $($Arguments -join ' ')"
    }
}

function New-SparseCheckout {
    if (Test-Path $repoDir) {
        Remove-Item -Path $repoDir -Recurse -Force
    }

    Write-SyncLog 'Creating new sparse checkout.'

    try {
        Invoke-SkylineNativeCommand -FilePath 'git' -Arguments @(
            'clone',
            '--quiet',
            '--filter=blob:none',
            '--sparse',
            '--branch',
            $branch,
            $repoUrl,
            $repoDir
        )
    }
    catch {
        Write-SyncLog "Filtered sparse clone failed. Retrying without blob filter. Error: $($_.Exception.Message)"

        if (Test-Path $repoDir) {
            Remove-Item -Path $repoDir -Recurse -Force
        }

        Invoke-SkylineNativeCommand -FilePath 'git' -Arguments @(
            'clone',
            '--quiet',
            '--sparse',
            '--branch',
            $branch,
            $repoUrl,
            $repoDir
        )
    }

    Invoke-SkylineNativeCommand -FilePath 'git' -Arguments @(
        '-C',
        $repoDir,
        'sparse-checkout',
        'set',
        'skills'
    )
}

function Update-SparseCheckout {
    Write-SyncLog 'Updating existing sparse checkout.'

    Invoke-SkylineNativeCommand -FilePath 'git' -Arguments @(
        '-C',
        $repoDir,
        'fetch',
        '--quiet',
        '--depth=1',
        'origin',
        $branch
    )

    Invoke-SkylineNativeCommand -FilePath 'git' -Arguments @(
        '-C',
        $repoDir,
        'checkout',
        '--quiet',
        '--force',
        'FETCH_HEAD'
    )

    Invoke-SkylineNativeCommand -FilePath 'git' -Arguments @(
        '-C',
        $repoDir,
        'sparse-checkout',
        'set',
        'skills'
    )
}

try {
    New-Item -Path $syncRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $destinationSkillsDir -ItemType Directory -Force | Out-Null

    Write-SyncLog 'Starting Skyline Copilot skills sync.'

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git was not found. Please install Git and try again.'
    }

    if (Test-Path (Join-Path $repoDir '.git')) {
        try {
            Update-SparseCheckout
        }
        catch {
            Write-SyncLog "Updating sparse checkout failed. Recreating checkout. Error: $($_.Exception.Message)"
            New-SparseCheckout
        }
    }
    else {
        New-SparseCheckout
    }

    if (-not (Test-Path $sourceSkillsDir)) {
        throw "Expected skills folder was not found: $sourceSkillsDir"
    }

    $skillDirectories = Get-ChildItem -Path $sourceSkillsDir -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') }

    if (-not $skillDirectories) {
        throw "No skills were found in: $sourceSkillsDir"
    }

    $currentSkillNames = @($skillDirectories | ForEach-Object { $_.Name })

    $previousSkillNames = @()

    if (Test-Path $installedSkillsFile) {
        $previousSkillNames = @(Get-Content -Path $installedSkillsFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    foreach ($previousSkillName in $previousSkillNames) {
        if ($currentSkillNames -notcontains $previousSkillName) {
            $oldDestination = Join-Path $destinationSkillsDir $previousSkillName

            if (Test-Path $oldDestination) {
                Remove-Item -Path $oldDestination -Recurse -Force
                Write-SyncLog "Removed old Skyline skill: $previousSkillName"
            }
        }
    }

    Get-ChildItem -Path $destinationSkillsDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName '.skyline-copilot-managed') } |
        Where-Object { $currentSkillNames -notcontains $_.Name } |
        ForEach-Object {
            Remove-Item -Path $_.FullName -Recurse -Force
            Write-SyncLog "Removed old managed Skyline skill: $($_.Name)"
        }

    foreach ($skillDirectory in $skillDirectories) {
        $destination = Join-Path $destinationSkillsDir $skillDirectory.Name

        if (Test-Path $destination) {
            Remove-Item -Path $destination -Recurse -Force
        }

        Copy-Item -Path $skillDirectory.FullName -Destination $destination -Recurse -Force

        Set-Content `
            -Path (Join-Path $destination '.skyline-copilot-managed') `
            -Value 'Managed by Skyline Copilot skills sync.' `
            -Encoding UTF8

        Write-SyncLog "Synced Skyline skill: $($skillDirectory.Name)"
    }

    $currentSkillNames | Set-Content -Path $installedSkillsFile -Encoding UTF8

    Write-SyncLog 'Skyline Copilot skills sync completed successfully.'
    Write-Host "Skyline Copilot skills synced to: $destinationSkillsDir"
}
catch {
    Write-SyncLog "ERROR: $($_.Exception.Message)"
    throw
}
'@

Set-Content -Path $syncScriptPath -Value $syncScript -Encoding UTF8

$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$wscriptExe = Join-Path $env:SystemRoot 'System32\wscript.exe'

$powershellExeForVbs = $powershellExe -replace '"', '""'
$syncScriptPathForVbs = $syncScriptPath -replace '"', '""'

$launcherScript = @"
Set shell = CreateObject("WScript.Shell")
q = Chr(34)
powershellPath = "$powershellExeForVbs"
scriptPath = "$syncScriptPathForVbs"
command = q & powershellPath & q & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & q & scriptPath & q
shell.Run command, 0, False
"@

Set-Content -Path $launcherScriptPath -Value $launcherScript -Encoding ASCII

Write-Host "Running initial Skyline Copilot skills sync..." -ForegroundColor Cyan

Invoke-SkylineNativeCommand -FilePath $powershellExe -Arguments @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $syncScriptPath
)

Write-Host "Creating or updating scheduled task..." -ForegroundColor Cyan

$startTime = (Get-Date).AddMinutes(1).ToString('HH:mm')
$taskCommand = "`"$wscriptExe`" `"$launcherScriptPath`""

Invoke-SkylineNativeCommand -FilePath 'schtasks.exe' -Arguments @(
    '/Create',
    '/TN',
    $taskName,
    '/SC',
    'HOURLY',
    '/MO',
    '3',
    '/ST',
    $startTime,
    '/TR',
    $taskCommand,
    '/F'
)

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Skills folder: $HOME\.copilot\skills"
Write-Host "Sync script: $syncScriptPath"
Write-Host "Hidden launcher: $launcherScriptPath"
Write-Host "Scheduled task: $taskName"
Write-Host "The skills will refresh every 3 hours."
Write-Host "Running this installer again is safe: it updates the sync script, runs a fresh sync, and replaces the scheduled task."
Write-Host "Restart Copilot CLI, Visual Studio, or VS Code to load the updated skills."
