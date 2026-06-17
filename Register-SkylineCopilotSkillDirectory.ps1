$ErrorActionPreference = 'Stop'

# This script:
# - Clones or updates the SkylineCommunications/.github-private repository to:
#   C:\Skyline GitHub Copilot Skills
# - Adds C:\Skyline GitHub Copilot Skills\skills to the user's Copilot CLI settings.json
# - Does not store credentials, tokens, or passwords
# - Requires the user to already have Git access to the private repository
# - Preserves existing skillDirectories entries and only adds the Skyline path if missing
# - Creates $HOME\.copilot and $HOME\.copilot\settings.json if they do not exist yet

$repoUrl = 'https://github.com/SkylineCommunications/.github-private.git'
$sourceRepoDir = 'C:\Skyline GitHub Copilot Skills'
$skillsDir = Join-Path $sourceRepoDir 'skills'

$copilotSettingsDir = Join-Path $HOME '.copilot'
$settingsPath = Join-Path $copilotSettingsDir 'settings.json'

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($output) {
        $output | ForEach-Object { Write-Host $_ }
    }

    if ($exitCode -ne 0) {
        throw "Command failed with exit code $exitCode`: $FilePath $($Arguments -join ' ')"
    }
}

function Remove-JsonComments {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Json
    )

    $result = New-Object System.Text.StringBuilder
    $inString = $false
    $escaped = $false
    $i = 0

    while ($i -lt $Json.Length) {
        $char = $Json[$i]
        $next = if ($i + 1 -lt $Json.Length) { $Json[$i + 1] } else { [char]0 }

        if ($inString) {
            [void]$result.Append($char)

            if ($escaped) {
                $escaped = $false
            }
            elseif ($char -eq '\') {
                $escaped = $true
            }
            elseif ($char -eq '"') {
                $inString = $false
            }

            $i++
            continue
        }

        if ($char -eq '"') {
            $inString = $true
            [void]$result.Append($char)
            $i++
            continue
        }

        if ($char -eq '/' -and $next -eq '/') {
            while ($i -lt $Json.Length -and $Json[$i] -ne "`n") {
                $i++
            }

            if ($i -lt $Json.Length) {
                [void]$result.Append("`n")
                $i++
            }

            continue
        }

        if ($char -eq '/' -and $next -eq '*') {
            $i += 2

            while ($i + 1 -lt $Json.Length -and -not ($Json[$i] -eq '*' -and $Json[$i + 1] -eq '/')) {
                if ($Json[$i] -eq "`n") {
                    [void]$result.Append("`n")
                }

                $i++
            }

            $i += 2
            continue
        }

        [void]$result.Append($char)
        $i++
    }

    return $result.ToString()
}

function Remove-TrailingJsonCommas {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Json
    )

    $result = New-Object System.Text.StringBuilder
    $inString = $false
    $escaped = $false
    $i = 0

    while ($i -lt $Json.Length) {
        $char = $Json[$i]

        if ($inString) {
            [void]$result.Append($char)

            if ($escaped) {
                $escaped = $false
            }
            elseif ($char -eq '\') {
                $escaped = $true
            }
            elseif ($char -eq '"') {
                $inString = $false
            }

            $i++
            continue
        }

        if ($char -eq '"') {
            $inString = $true
            [void]$result.Append($char)
            $i++
            continue
        }

        if ($char -eq ',') {
            $lookAhead = $i + 1

            while ($lookAhead -lt $Json.Length -and [char]::IsWhiteSpace($Json[$lookAhead])) {
                $lookAhead++
            }

            if ($lookAhead -lt $Json.Length -and ($Json[$lookAhead] -eq '}' -or $Json[$lookAhead] -eq ']')) {
                $i++
                continue
            }
        }

        [void]$result.Append($char)
        $i++
    }

    return $result.ToString()
}

function Normalize-PathForComparison {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    return $Path.Trim().TrimEnd('\', '/').ToLowerInvariant()
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git was not found. Please install Git and try again."
}

Write-Host "Cloning or updating Skyline GitHub Copilot skills..." -ForegroundColor Cyan

if (Test-Path (Join-Path $sourceRepoDir '.git')) {
    Invoke-NativeCommand -FilePath 'git' -Arguments @('-C', $sourceRepoDir, 'pull', '--ff-only')
}
elseif (Test-Path $sourceRepoDir) {
    $existingItems = Get-ChildItem -Path $sourceRepoDir -Force | Select-Object -First 1

    if ($existingItems) {
        throw "Target directory already exists and is not an empty Git repository: $sourceRepoDir"
    }

    Invoke-NativeCommand -FilePath 'git' -Arguments @('clone', $repoUrl, $sourceRepoDir)
}
else {
    Invoke-NativeCommand -FilePath 'git' -Arguments @('clone', $repoUrl, $sourceRepoDir)
}

if (-not (Test-Path $skillsDir)) {
    throw "Expected skills folder was not found: $skillsDir"
}

Write-Host "Updating Copilot settings..." -ForegroundColor Cyan

# Make sure the Copilot settings folder exists.
New-Item -Path $copilotSettingsDir -ItemType Directory -Force | Out-Null

# Make sure the Copilot settings file exists.
if (-not (Test-Path $settingsPath)) {
    '{}' | Set-Content -Path $settingsPath -Encoding UTF8
}

$rawSettings = Get-Content -Path $settingsPath -Raw

if ([string]::IsNullOrWhiteSpace($rawSettings)) {
    $rawSettings = '{}'
}

$jsonWithoutComments = Remove-JsonComments -Json $rawSettings
$jsonWithoutTrailingCommas = Remove-TrailingJsonCommas -Json $jsonWithoutComments

try {
    $settings = $jsonWithoutTrailingCommas | ConvertFrom-Json
}
catch {
    throw "Could not parse Copilot settings file: $settingsPath. The file may contain invalid JSON/JSONC."
}

if (-not $settings) {
    $settings = [pscustomobject]@{}
}

$existingSkillDirectories = @()

if ($settings.PSObject.Properties.Name -contains 'skillDirectories' -and $null -ne $settings.skillDirectories) {
    $existingSkillDirectories = @($settings.skillDirectories)
}

$normalizedExistingDirectories = $existingSkillDirectories |
    ForEach-Object { Normalize-PathForComparison -Path $_ }

$normalizedSkillsDir = Normalize-PathForComparison -Path $skillsDir

if ($normalizedExistingDirectories -contains $normalizedSkillsDir) {
    Write-Host "Skill directory already exists in settings.json: $skillsDir" -ForegroundColor Yellow
}
else {
    $updatedSkillDirectories = @($existingSkillDirectories) + $skillsDir

    if ($settings.PSObject.Properties.Name -contains 'skillDirectories') {
        $settings.skillDirectories = $updatedSkillDirectories
    }
    else {
        $settings | Add-Member -MemberType NoteProperty -Name 'skillDirectories' -Value $updatedSkillDirectories
    }

    $settings |
        ConvertTo-Json -Depth 20 |
        Set-Content -Path $settingsPath -Encoding UTF8

    Write-Host "Added skill directory to settings.json: $skillsDir" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Settings file: $settingsPath"
Write-Host "In an existing Copilot CLI session, run: /skills reload"
Write-Host "Then verify with: /skills list"
