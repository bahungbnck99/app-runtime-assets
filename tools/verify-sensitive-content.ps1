param(
  [string]$ManifestPath = "",
  [string]$ArchivePath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
  $ManifestPath = Join-Path $repoRoot "manifests\sensitive-content.candidate.json"
} elseif (-not [System.IO.Path]::IsPathRooted($ManifestPath)) {
  $ManifestPath = Join-Path $repoRoot $ManifestPath
}
if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
  $ArchivePath = Join-Path $repoRoot "packs\sensitive-content\sensitive-content-windows-x86_64.zip"
} elseif (-not [System.IO.Path]::IsPathRooted($ArchivePath)) {
  $ArchivePath = Join-Path $repoRoot $ArchivePath
}
$ManifestPath = (Resolve-Path -LiteralPath $ManifestPath).Path
$ArchivePath = (Resolve-Path -LiteralPath $ArchivePath).Path
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$verifyRoot = Join-Path $repoRoot ".work\verify-sensitive-content"

function Get-Sha256([string]$Path) {
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Assert-SafeRelativePath([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value) -or
      [System.IO.Path]::IsPathRooted($Value) -or
      $Value.Contains(":") -or
      $Value.Contains([char]0)) {
    throw "Unsafe archive path: $Value"
  }
  $normalized = $Value.Replace("\", "/").TrimEnd("/")
  foreach ($part in $normalized.Split("/")) {
    if ([string]::IsNullOrWhiteSpace($part) -or $part -eq "." -or $part -eq "..") {
      throw "Unsafe archive path: $Value"
    }
  }
  return $normalized
}

function Reset-VerifyRoot {
  $fullPath = [System.IO.Path]::GetFullPath($verifyRoot)
  $safeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot ".work"))
  if (-not $fullPath.StartsWith($safeRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to reset a verifier path outside .work."
  }
  if (Test-Path -LiteralPath $fullPath) {
    Remove-Item -LiteralPath $fullPath -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $fullPath | Out-Null
}

if ($manifest.schemaVersion -ne 1 -or $manifest.assetType -ne "sensitive-content") {
  throw "Manifest identity is invalid."
}
if ($manifest.os -ne "windows" -or $manifest.arch -ne "x86_64" -or $manifest.installMode -ne "zip") {
  throw "Manifest platform/installMode is invalid."
}
if ([string]$manifest.packSha256 -notmatch "^[a-f0-9]{64}$") {
  throw "Manifest packSha256 is invalid."
}
$actualPackHash = Get-Sha256 $ArchivePath
if ($actualPackHash -ne [string]$manifest.packSha256) {
  throw "Archive SHA-256 mismatch. Expected $($manifest.packSha256), got $actualPackHash."
}

$expected = @{}
foreach ($file in $manifest.files) {
  $relative = Assert-SafeRelativePath ([string]$file.path)
  $key = $relative.ToLowerInvariant()
  if ($expected.ContainsKey($key)) {
    throw "Manifest contains a duplicate path identity: $relative"
  }
  if ([int64]$file.bytes -le 0 -or [string]$file.sha256 -notmatch "^[a-f0-9]{64}$") {
    throw "Manifest file integrity metadata is invalid: $relative"
  }
  $expected[$key] = $file
}
foreach ($license in $manifest.licenses) {
  $key = (Assert-SafeRelativePath ([string]$license)).ToLowerInvariant()
  if (-not $expected.ContainsKey($key)) {
    throw "Manifest license is not present in the signed file inventory: $license"
  }
}
$workerKey = (Assert-SafeRelativePath ([string]$manifest.workerFile)).ToLowerInvariant()
if (-not $expected.ContainsKey($workerKey)) {
  throw "Manifest workerFile is not present in the signed file inventory."
}

Reset-VerifyRoot
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$seen = @{}
$zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
try {
  foreach ($entry in $zip.Entries) {
    if ([string]::IsNullOrEmpty($entry.Name)) {
      continue
    }
    $relative = Assert-SafeRelativePath $entry.FullName
    $key = $relative.ToLowerInvariant()
    if ($seen.ContainsKey($key)) {
      throw "Archive contains a duplicate path identity: $relative"
    }
    $unixType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
    if ($unixType -eq 0xA000) {
      throw "Archive may not contain symbolic links: $relative"
    }
    if (-not $expected.ContainsKey($key)) {
      throw "Archive contains a file outside the signed inventory: $relative"
    }
    $destination = Join-Path $verifyRoot $relative.Replace("/", "\")
    $parent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $false)
    $seen[$key] = $destination
  }
} finally {
  $zip.Dispose()
}

if ($seen.Count -ne $expected.Count) {
  $missing = @($expected.Keys | Where-Object { -not $seen.ContainsKey($_) })
  throw "Archive is missing signed inventory files: $($missing -join ', ')"
}
foreach ($key in $expected.Keys) {
  $item = $expected[$key]
  $path = [string]$seen[$key]
  if ((Get-Item -LiteralPath $path).Length -ne [int64]$item.bytes) {
    throw "Extracted file size mismatch: $($item.path)"
  }
  if ((Get-Sha256 $path) -ne [string]$item.sha256) {
    throw "Extracted file SHA-256 mismatch: $($item.path)"
  }
}

$worker = [string]$seen[$workerKey]
$start = New-Object System.Diagnostics.ProcessStartInfo
$start.FileName = $worker
$start.Arguments = "--health-json"
$start.WorkingDirectory = $verifyRoot
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $start
if (-not $process.Start()) {
  throw "Verified worker could not start."
}
if (-not $process.WaitForExit(10000)) {
  $process.Kill()
  throw "Verified worker health check timed out."
}
$stdout = $process.StandardOutput.ReadToEnd()
$stderr = $process.StandardError.ReadToEnd()
if ($process.ExitCode -ne 0) {
  throw "Verified worker health check failed: $stderr"
}
$health = $stdout | ConvertFrom-Json
if ($health.status -ne "ready" -or $health.schemaVersion -ne 1) {
  throw "Verified worker returned an invalid health response."
}

Write-Host "Sensitive-content archive verified:"
Write-Host "  Manifest:    $ManifestPath"
Write-Host "  Archive:     $ArchivePath"
Write-Host "  Files:       $($expected.Count)"
Write-Host "  Pack SHA256: $actualPackHash"
Write-Host "  Health:      ready / schemaVersion 1"
