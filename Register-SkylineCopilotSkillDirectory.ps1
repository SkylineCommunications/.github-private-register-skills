$ErrorActionPreference = 'Stop'

# This script:
# - Adds the shared Skyline Copilot skills directory to the user's Copilot CLI settings.json
# - Does not clone, copy, or update any files
# - Preserves existing settings and existing skillDirectories entries
# - Creates $HOME\.copilot and settings.json if they do not exist yet
# - Supports Windows PowerShell 5.1 and PowerShell 7+

$skillDirectoryToAdd = '\\SLC-NAS-01.skyline.local\Shares\Public\Skyline Copilot Skills\.github-private\skills'

$copilotSettingsDir = Join-Path $HOME '.copilot'
$settingsPath = Join-Path $copilotSettingsDir 'settings.json'

function Normalize-PathForComparison {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    return $Path.Trim().TrimEnd('\', '/').ToLowerInvariant()
}

Write-Host "Updating Copilot settings..." -ForegroundColor Cyan

New-Item -Path $copilotSettingsDir -ItemType Directory -Force | Out-Null

if (-not (Test-Path $settingsPath)) {
    '{}' | Set-Content -Path $settingsPath -Encoding UTF8
}

$rawSettings = Get-Content -Path $settingsPath -Raw

if ([string]::IsNullOrWhiteSpace($rawSettings)) {
    $rawSettings = '{}'
}

try {
    $settings = $rawSettings | ConvertFrom-Json
}
catch {
    throw "Could not parse Copilot settings file: $settingsPath. Please check that it contains valid JSON."
}

if (-not $settings) {
    $settings = New-Object psobject
}

$existingSkillDirectories = @()

if ($settings.PSObject.Properties.Name -contains 'skillDirectories' -and $null -ne $settings.skillDirectories) {
    $existingSkillDirectories = @($settings.skillDirectories)
}

$normalizedExistingSkillDirectories = $existingSkillDirectories |
    Where-Object { $null -ne $_ } |
    ForEach-Object { Normalize-PathForComparison -Path $_ }

$normalizedSkillDirectoryToAdd = Normalize-PathForComparison -Path $skillDirectoryToAdd

if ($normalizedExistingSkillDirectories -contains $normalizedSkillDirectoryToAdd) {
    Write-Host "Skill directory already exists in settings.json:" -ForegroundColor Yellow
    Write-Host $skillDirectoryToAdd
}
else {
    $updatedSkillDirectories = @($existingSkillDirectories) + $skillDirectoryToAdd

    if ($settings.PSObject.Properties.Name -contains 'skillDirectories') {
        $settings.skillDirectories = $updatedSkillDirectories
    }
    else {
        $settings | Add-Member -MemberType NoteProperty -Name 'skillDirectories' -Value $updatedSkillDirectories
    }

    $backupPath = "$settingsPath.bak"
    Copy-Item -Path $settingsPath -Destination $backupPath -Force

    $settings |
        ConvertTo-Json -Depth 20 |
        Set-Content -Path $settingsPath -Encoding UTF8

    Write-Host "Added skill directory to settings.json:" -ForegroundColor Green
    Write-Host $skillDirectoryToAdd
    Write-Host "Previous settings backed up to: $backupPath"
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Settings file: $settingsPath"
Write-Host "Restart Copilot CLI to load the updated skillDirectories setting."
Write-Host "After restarting, verify with: /skills list"
