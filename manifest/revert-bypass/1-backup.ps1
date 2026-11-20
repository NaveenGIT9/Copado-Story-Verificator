# Run BEFORE deploying the bypass change. Saves the org's current versions of the components it modifies.
param([string]$Org = 'RBKPIPEQA')
$ErrorActionPreference = 'Stop'
$kit = $PSScriptRoot
$backup = Join-Path $kit 'backup'
if (Test-Path $backup) { throw "A backup already exists at $backup. Move it aside first; it may be the only copy of the pre-change org state." }

sf project retrieve start --manifest (Join-Path $kit 'backup-package.xml') --target-metadata-dir $backup --unzip --target-org $Org
if ($LASTEXITCODE -ne 0) { throw 'Retrieve failed.' }

$pkg = Get-ChildItem $backup -Recurse -Filter package.xml | Select-Object -First 1
Write-Host "Backup saved under $($pkg.DirectoryName)"
Get-ChildItem $pkg.DirectoryName -Recurse -File | ForEach-Object { $_.FullName.Substring($pkg.DirectoryName.Length + 1) }
