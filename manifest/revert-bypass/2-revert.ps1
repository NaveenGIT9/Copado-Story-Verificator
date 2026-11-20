# Puts RBKPIPEQA back to the state saved by 1-backup.ps1 and deletes the bypass components.
# Validates only (dry run) unless -Apply is passed.
param([string]$Org = 'RBKPIPEQA', [switch]$Apply)
$ErrorActionPreference = 'Stop'
$kit = $PSScriptRoot
$pkg = Get-ChildItem (Join-Path $kit 'backup') -Recurse -Filter package.xml -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $pkg) { throw 'No backup found. 1-backup.ps1 must have been run before the change was deployed.' }

Copy-Item (Join-Path $kit 'destructiveChangesPost.xml') $pkg.DirectoryName -Force

$deployArgs = @('project', 'deploy', 'start', '--metadata-dir', $pkg.DirectoryName, '--target-org', $Org, '--test-level', 'NoTestRun', '--wait', '30')
if (-not $Apply) { $deployArgs += '--dry-run' }
& sf @deployArgs
if ($LASTEXITCODE -ne 0) { throw 'Revert deploy failed.' }
if (-not $Apply) { Write-Host 'Validation passed. Run again with -Apply to revert.' }
