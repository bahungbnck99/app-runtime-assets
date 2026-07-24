param(
  [string]$DefinitionPath = "",
  [string]$UpstreamArchivePath = "",
  [switch]$ForceDownload,
  [string]$Owner = "bahungbnck99",
  [string]$Repo = "app-runtime-assets",
  [string]$Branch = "main"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($DefinitionPath)) {
  $DefinitionPath = Join-Path $repoRoot "sources\ffmpeg-windows-x64-8.1-r1.json"
} elseif (-not [System.IO.Path]::IsPathRooted($DefinitionPath)) {
  $DefinitionPath = Join-Path $repoRoot $DefinitionPath
}
$DefinitionPath = (Resolve-Path -LiteralPath $DefinitionPath).Path
$definition = Get-Content -LiteralPath $DefinitionPath -Raw | ConvertFrom-Json

if ($definition.schemaVersion -ne 1) {
  throw "Unsupported FFmpeg source definition schema: $($definition.schemaVersion)"
}
if ($definition.os -ne "windows" -or $definition.arch -ne "x86_64") {
  throw "This workflow only packages Windows x86_64 FFmpeg."
}

$runtimeVersion = [string]$definition.runtimeVersion
$inputMode = if ($definition.PSObject.Properties["inputMode"]) {
  [string]$definition.inputMode
} else {
  "download"
}
$expectedBinaryVersion = if ($definition.PSObject.Properties["expectedBinaryVersion"]) {
  [string]$definition.expectedBinaryVersion
} else {
  ""
}
$upstreamArchiveName = [string]$definition.upstream.archiveName
$upstreamUrl = [string]$definition.upstream.url
$expectedUpstreamSha256 = ([string]$definition.upstream.sha256).ToLowerInvariant()
$expectedUpstreamSize = [int64]$definition.upstream.size
$releaseArchiveName = [string]$definition.release.archiveName
$releaseTag = [string]$definition.release.tag
$packUrl = [string]$definition.release.packUrl

if ($expectedUpstreamSha256 -notmatch "^[a-f0-9]{64}$") {
  throw "The pinned upstream SHA-256 is invalid."
}
if ($releaseArchiveName -ne "ffmpeg-windows-x64-$runtimeVersion.zip") {
  throw "Release archive name must match runtimeVersion."
}
if ($releaseTag -ne "ffmpeg-windows-x64-$runtimeVersion") {
  throw "Release tag must match runtimeVersion."
}

$workRoot = Join-Path $repoRoot ".work\ffmpeg-$runtimeVersion"
$downloadDir = Join-Path $repoRoot ".work\downloads"
$stagingDir = Join-Path $workRoot "staging"
$smokeDir = Join-Path $workRoot "smoke"
$packsDir = Join-Path $repoRoot "packs\ffmpeg"
$manifestsDir = Join-Path $repoRoot "manifests"
$checksumsDir = Join-Path $repoRoot "checksums"
$archivePath = Join-Path $packsDir $releaseArchiveName
$manifestPath = Join-Path $manifestsDir "ffmpeg.json"
$registryPath = Join-Path $manifestsDir "registry.json"
$checksumPath = Join-Path $checksumsDir "SHA256SUMS.txt"

New-Item -ItemType Directory -Force -Path $workRoot, $downloadDir, $packsDir, $manifestsDir, $checksumsDir | Out-Null

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Get-Sha256([string]$Path) {
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Assert-WorkPath([string]$Path) {
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $safeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot ".work"))
  if (-not $fullPath.StartsWith($safeRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to modify a path outside .work: $fullPath"
  }
}

function Reset-WorkDirectory([string]$Path) {
  Assert-WorkPath $Path
  if (Test-Path -LiteralPath $Path) {
    Remove-Item -LiteralPath $Path -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Download-File([string]$Url, [string]$Destination) {
  $temporaryPath = "$Destination.download"
  Assert-WorkPath $temporaryPath
  if (Test-Path -LiteralPath $temporaryPath) {
    Remove-Item -LiteralPath $temporaryPath -Force
  }

  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Add-Type -AssemblyName System.Net.Http
  $handler = New-Object System.Net.Http.HttpClientHandler
  $handler.AllowAutoRedirect = $true
  $client = New-Object System.Net.Http.HttpClient($handler)
  $client.DefaultRequestHeaders.UserAgent.ParseAdd("app-runtime-assets-packager/1.0")
  $response = $null
  try {
    $response = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    [void]$response.EnsureSuccessStatusCode()
    $input = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $output = [System.IO.File]::Open($temporaryPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
      $buffer = New-Object byte[] (1024 * 1024)
      while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $output.Write($buffer, 0, $read)
      }
    } finally {
      $output.Dispose()
      $input.Dispose()
    }
  } finally {
    if ($null -ne $response) { $response.Dispose() }
    $client.Dispose()
    $handler.Dispose()
  }
  Move-Item -LiteralPath $temporaryPath -Destination $Destination -Force
}

function Get-ArchiveEntry([System.IO.Compression.ZipArchive]$Archive, [string]$Suffix) {
  $normalizedSuffix = $Suffix.Replace("\", "/")
  $matches = @($Archive.Entries | Where-Object {
    $_.FullName.Replace("\", "/").EndsWith($normalizedSuffix, [System.StringComparison]::OrdinalIgnoreCase)
  })
  if ($matches.Count -ne 1) {
    throw "Expected exactly one upstream archive entry ending with '$normalizedSuffix'; found $($matches.Count)."
  }
  return $matches[0]
}

function Extract-ArchiveEntry([System.IO.Compression.ZipArchiveEntry]$Entry, [string]$Destination) {
  $parent = Split-Path -Parent $Destination
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  [System.IO.Compression.ZipFileExtensions]::ExtractToFile($Entry, $Destination, $true)
}

function Invoke-Captured([string]$Executable, [string[]]$Arguments) {
  $output = @(& $Executable @Arguments 2>&1 | ForEach-Object { "$_" })
  if ($LASTEXITCODE -ne 0) {
    throw "$([System.IO.Path]::GetFileName($Executable)) failed with exit code $LASTEXITCODE.`n$($output -join [Environment]::NewLine)"
  }
  return $output
}

function New-DeterministicZip([string]$SourceDirectory, [string]$Destination) {
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem

  if (Test-Path -LiteralPath $Destination) {
    Remove-Item -LiteralPath $Destination -Force
  }

  $sourceRoot = [System.IO.Path]::GetFullPath($SourceDirectory).TrimEnd("\", "/")
  $files = @(Get-ChildItem -LiteralPath $sourceRoot -File -Recurse | Sort-Object {
    $_.FullName.Substring($sourceRoot.Length + 1).Replace("\", "/")
  })
  $stream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
  $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
  $fixedTimestamp = New-Object System.DateTimeOffset(2000, 1, 1, 0, 0, 0, [System.TimeSpan]::Zero)
  try {
    foreach ($file in $files) {
      $relativePath = $file.FullName.Substring($sourceRoot.Length + 1).Replace("\", "/")
      $entry = $archive.CreateEntry($relativePath, [System.IO.Compression.CompressionLevel]::Optimal)
      $entry.LastWriteTime = $fixedTimestamp
      $input = [System.IO.File]::OpenRead($file.FullName)
      $output = $entry.Open()
      try {
        $input.CopyTo($output)
      } finally {
        $output.Dispose()
        $input.Dispose()
      }
    }
  } finally {
    $archive.Dispose()
    $stream.Dispose()
  }
}

if ([string]::IsNullOrWhiteSpace($UpstreamArchivePath)) {
  $UpstreamArchivePath = Join-Path $downloadDir $upstreamArchiveName
  if ($inputMode -eq "preservedArchive") {
    if ($ForceDownload) {
      throw "ForceDownload is not supported for a preserved FFmpeg archive."
    }
    if (-not (Test-Path -LiteralPath $UpstreamArchivePath)) {
      throw "The pinned preserved FFmpeg archive is missing: $UpstreamArchivePath. Restore it locally or pass -UpstreamArchivePath."
    }
  } elseif ($ForceDownload -or -not (Test-Path -LiteralPath $UpstreamArchivePath)) {
    Write-Host "Downloading pinned upstream FFmpeg archive..."
    Download-File -Url $upstreamUrl -Destination $UpstreamArchivePath
  }
} elseif (-not [System.IO.Path]::IsPathRooted($UpstreamArchivePath)) {
  $UpstreamArchivePath = Join-Path $repoRoot $UpstreamArchivePath
}
$UpstreamArchivePath = (Resolve-Path -LiteralPath $UpstreamArchivePath).Path

$upstreamHash = Get-Sha256 $UpstreamArchivePath
if ($upstreamHash -ne $expectedUpstreamSha256) {
  throw "Upstream SHA-256 mismatch. Expected $expectedUpstreamSha256, got $upstreamHash. The floating 'latest' asset changed or the file is corrupt."
}
$upstreamSize = (Get-Item -LiteralPath $UpstreamArchivePath).Length
if ($upstreamSize -ne $expectedUpstreamSize) {
  throw "Upstream size mismatch. Expected $expectedUpstreamSize bytes, got $upstreamSize bytes."
}

Reset-WorkDirectory $stagingDir
Reset-WorkDirectory $smokeDir

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$upstreamZip = [System.IO.Compression.ZipFile]::OpenRead($UpstreamArchivePath)
try {
  $ffmpegEntry = Get-ArchiveEntry $upstreamZip "/bin/ffmpeg.exe"
  $ffprobeEntry = Get-ArchiveEntry $upstreamZip "/bin/ffprobe.exe"
  $licenseEntry = Get-ArchiveEntry $upstreamZip "/LICENSE.txt"
  Extract-ArchiveEntry $ffmpegEntry (Join-Path $stagingDir "bin\ffmpeg.exe")
  Extract-ArchiveEntry $ffprobeEntry (Join-Path $stagingDir "bin\ffprobe.exe")
  Extract-ArchiveEntry $licenseEntry (Join-Path $stagingDir "LICENSES\FFmpeg-GPL-3.0.txt")
} finally {
  $upstreamZip.Dispose()
}

$ffmpegPath = Join-Path $stagingDir "bin\ffmpeg.exe"
$ffprobePath = Join-Path $stagingDir "bin\ffprobe.exe"
$ffmpegSha256 = Get-Sha256 $ffmpegPath
$ffprobeSha256 = Get-Sha256 $ffprobePath

$ffmpegVersionOutput = Invoke-Captured $ffmpegPath @("-hide_banner", "-version")
$ffprobeVersionOutput = Invoke-Captured $ffprobePath @("-hide_banner", "-version")
$ffmpegVersionLine = $ffmpegVersionOutput | Select-Object -First 1
$ffprobeVersionLine = $ffprobeVersionOutput | Select-Object -First 1
$actualVersion = ($ffmpegVersionLine -replace "^ffmpeg version\s+", "").Split(" ")[0]
$probeActualVersion = ($ffprobeVersionLine -replace "^ffprobe version\s+", "").Split(" ")[0]
if ($actualVersion -ne $probeActualVersion) {
  throw "ffmpeg and ffprobe versions differ: $actualVersion vs $probeActualVersion"
}
if (-not [string]::IsNullOrWhiteSpace($expectedBinaryVersion)) {
  if ($actualVersion -ne $expectedBinaryVersion) {
    throw "Unexpected FFmpeg binary version. Expected $expectedBinaryVersion, got $actualVersion"
  }
} elseif ($actualVersion -notmatch "^n8\.1(\.|-|$)") {
  throw "Unexpected FFmpeg release branch: $actualVersion"
}

$filterOutput = Invoke-Captured $ffmpegPath @("-hide_banner", "-filters")
$encoderOutput = Invoke-Captured $ffmpegPath @("-hide_banner", "-encoders")
foreach ($requiredFilter in @("drawtext", "subtitles", "xfade")) {
  if (-not ($filterOutput -match "\b$requiredFilter\b")) {
    throw "Required FFmpeg filter is missing: $requiredFilter"
  }
}
foreach ($requiredEncoder in @("libx264", "libx265", "aac")) {
  if (-not ($encoderOutput -match "\b$requiredEncoder\b")) {
    throw "Required FFmpeg encoder is missing: $requiredEncoder"
  }
}

$smokeVideo = Join-Path $smokeDir "probe-smoke.mp4"
[void](Invoke-Captured $ffmpegPath @(
  "-hide_banner", "-loglevel", "error",
  "-f", "lavfi", "-i", "color=c=black:s=64x64:r=1:d=1",
  "-c:v", "libx264", "-pix_fmt", "yuv420p",
  "-movflags", "+faststart", "-y", $smokeVideo
))
$probeOutput = Invoke-Captured $ffprobePath @(
  "-v", "error",
  "-select_streams", "v:0",
  "-show_entries", "stream=codec_name,width,height",
  "-of", "default=noprint_wrappers=1", $smokeVideo
)
if (-not ($probeOutput -contains "codec_name=h264") -or
    -not ($probeOutput -contains "width=64") -or
    -not ($probeOutput -contains "height=64")) {
  throw "FFmpeg/ffprobe smoke test returned unexpected metadata: $($probeOutput -join ', ')"
}

$sourceRevision = ""
if ($actualVersion -match "-g([0-9a-f]{7,40})-") {
  $sourceRevision = $Matches[1]
}
$sourceCodeUrl = if ($sourceRevision) {
  "https://github.com/FFmpeg/FFmpeg/tree/$sourceRevision"
} else {
  "https://github.com/FFmpeg/FFmpeg/tree/release/8.1"
}

$sourceNotice = @"
FFmpeg source and license information
=====================================

This package redistributes unmodified ffmpeg.exe and ffprobe.exe files from
the pinned BtbN/FFmpeg-Builds GPL static Windows x64 binary pair described
and verified in PROVENANCE.json.

FFmpeg corresponding source:
$sourceCodeUrl

FFmpeg source repository:
https://github.com/FFmpeg/FFmpeg

BtbN build scripts and dependency recipes:
https://github.com/BtbN/FFmpeg-Builds

The complete GNU GPL version 3 license text supplied by the upstream binary
archive is included as LICENSES/FFmpeg-GPL-3.0.txt.
"@
Write-Utf8NoBom -Path (Join-Path $stagingDir "LICENSES\SOURCE-CODE.txt") -Content ($sourceNotice.Trim() + "`n")

$provenance = [ordered]@{
  schemaVersion = 1
  assetType = "ffmpeg"
  runtimeVersion = $runtimeVersion
  os = "windows"
  arch = "x86_64"
  upstream = [ordered]@{
    project = [string]$definition.upstream.project
    inputMode = $inputMode
    archiveName = $upstreamArchiveName
    url = $upstreamUrl
    checksumsUrl = [string]$definition.upstream.checksumsUrl
    binaryOrigin = if ($definition.upstream.PSObject.Properties["binaryOrigin"]) {
      [string]$definition.upstream.binaryOrigin
    } else {
      ""
    }
    sha256 = $upstreamHash
    size = $upstreamSize
  }
  ffmpeg = [ordered]@{
    version = $actualVersion
    sourceRevision = $sourceRevision
    sourceUrl = $sourceCodeUrl
    sha256 = $ffmpegSha256
  }
  ffprobe = [ordered]@{
    version = $probeActualVersion
    sha256 = $ffprobeSha256
  }
  license = [ordered]@{
    spdx = [string]$definition.license.spdx
    file = "LICENSES/FFmpeg-GPL-3.0.txt"
    sourceInformation = "LICENSES/SOURCE-CODE.txt"
  }
  packaging = [ordered]@{
    tool = "tools/update-ffmpeg.ps1"
    deterministicZipTimestamp = "2000-01-01T00:00:00"
  }
}
Write-Utf8NoBom -Path (Join-Path $stagingDir "PROVENANCE.json") -Content (($provenance | ConvertTo-Json -Depth 10) + "`n")

$buildInfo = @"
Runtime version: $runtimeVersion
Platform: windows-x86_64
Upstream archive: $upstreamArchiveName
Upstream SHA-256: $upstreamHash
FFmpeg SHA-256: $ffmpegSha256
FFprobe SHA-256: $ffprobeSha256

$($ffmpegVersionOutput -join "`n")
"@
Write-Utf8NoBom -Path (Join-Path $stagingDir "BUILD-INFO.txt") -Content ($buildInfo.Trim() + "`n")

$packItems = @()
foreach ($relativePath in @(
  "bin/ffmpeg.exe",
  "bin/ffprobe.exe",
  "LICENSES/FFmpeg-GPL-3.0.txt",
  "LICENSES/SOURCE-CODE.txt",
  "PROVENANCE.json",
  "BUILD-INFO.txt"
)) {
  $localPath = Join-Path $stagingDir ($relativePath.Replace("/", "\"))
  $packItems += [ordered]@{
    file = $relativePath
    sha256 = Get-Sha256 $localPath
    size = (Get-Item -LiteralPath $localPath).Length
  }
}
$packMetadata = [ordered]@{
  schemaVersion = 1
  assetType = "ffmpeg"
  runtimeVersion = $runtimeVersion
  os = "windows"
  arch = "x86_64"
  license = [string]$definition.license.spdx
  items = $packItems
}
Write-Utf8NoBom -Path (Join-Path $stagingDir "pack.json") -Content (($packMetadata | ConvertTo-Json -Depth 10) + "`n")

New-DeterministicZip -SourceDirectory $stagingDir -Destination $archivePath
$packSha256 = Get-Sha256 $archivePath

$manifest = [ordered]@{
  schemaVersion = 1
  assetType = "ffmpeg"
  runtimeVersion = $runtimeVersion
  os = "windows"
  arch = "x86_64"
  installMode = "zip"
  packUrl = $packUrl
  packSha256 = $packSha256
  ffmpegSha256 = $ffmpegSha256
  ffprobeSha256 = $ffprobeSha256
}
Write-Utf8NoBom -Path $manifestPath -Content (($manifest | ConvertTo-Json -Depth 10) + "`n")

$registry = if (Test-Path -LiteralPath $registryPath) {
  Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
} else {
  [pscustomobject]@{
    schemaVersion = 1
    updatedAt = ""
    publisher = $Owner
    assets = [pscustomobject]@{}
  }
}
$registry.schemaVersion = 1
$registry.updatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$registry.publisher = $Owner
$ffmpegRegistryEntry = [ordered]@{
  manifestUrl = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch/manifests/ffmpeg.json"
  requiredBy = @("download-multi-platform")
  optional = $false
}
if ($registry.assets.PSObject.Properties["ffmpeg"]) {
  $registry.assets.ffmpeg = $ffmpegRegistryEntry
} else {
  $registry.assets | Add-Member -NotePropertyName "ffmpeg" -NotePropertyValue $ffmpegRegistryEntry
}
Write-Utf8NoBom -Path $registryPath -Content (($registry | ConvertTo-Json -Depth 10) + "`n")

$checksumLine = "$packSha256  packs/ffmpeg/$releaseArchiveName"
$existing = @()
if (Test-Path -LiteralPath $checksumPath) {
  $escapedArchive = [regex]::Escape("packs/ffmpeg/$releaseArchiveName")
  $existing = @(Get-Content -LiteralPath $checksumPath | Where-Object {
    $_ -and ($_ -notmatch "$escapedArchive$")
  })
}
Write-Utf8NoBom -Path $checksumPath -Content ((@($existing + $checksumLine) -join "`n") + "`n")

Write-Host "FFmpeg runtime package completed:"
Write-Host "  Runtime version: $runtimeVersion"
Write-Host "  Actual version:  $actualVersion"
Write-Host "  Archive:         $archivePath"
Write-Host "  Archive size:    $((Get-Item -LiteralPath $archivePath).Length) bytes"
Write-Host "  Pack SHA-256:    $packSha256"
Write-Host "  FFmpeg SHA-256:  $ffmpegSha256"
Write-Host "  FFprobe SHA-256: $ffprobeSha256"
Write-Host "  Manifest:        $manifestPath"
Write-Host "  Pack URL:        $packUrl"
