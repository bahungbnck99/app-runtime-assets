param(
  [string]$DefinitionPath = "",
  [string]$QualificationReportPath = "",
  [string]$RuntimeVersion = "1.0.0-candidate.2",
  [switch]$ForceDownload,
  [switch]$PublishManifest,
  [string]$Owner = "bahungbnck99",
  [string]$Repo = "app-runtime-assets",
  [string]$Branch = "main"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($DefinitionPath)) {
  $DefinitionPath = Join-Path $repoRoot "sources\sensitive-content-candidates-1.0.0.json"
} elseif (-not [System.IO.Path]::IsPathRooted($DefinitionPath)) {
  $DefinitionPath = Join-Path $repoRoot $DefinitionPath
}
$DefinitionPath = (Resolve-Path -LiteralPath $DefinitionPath).Path

if ([string]::IsNullOrWhiteSpace($QualificationReportPath)) {
  $QualificationReportPath = Join-Path $repoRoot "sensitive-content\qualification\qualification-template.json"
} elseif (-not [System.IO.Path]::IsPathRooted($QualificationReportPath)) {
  $QualificationReportPath = Join-Path $repoRoot $QualificationReportPath
}
$QualificationReportPath = (Resolve-Path -LiteralPath $QualificationReportPath).Path

$definition = Get-Content -LiteralPath $DefinitionPath -Raw | ConvertFrom-Json
$qualification = Get-Content -LiteralPath $QualificationReportPath -Raw | ConvertFrom-Json
$calibrationSource = Join-Path $repoRoot "sensitive-content\config\calibration.json"
$workerSource = Join-Path $repoRoot "sensitive-content\worker\sensitive_content_worker.py"
$workerSpec = Join-Path $repoRoot "sensitive-content\worker\sensitive_content_worker.spec"
$requirements = Join-Path $repoRoot "sensitive-content\worker\requirements-build.txt"
$testsDir = Join-Path $repoRoot "sensitive-content\tests"
$licensesSource = Join-Path $repoRoot "sensitive-content\licenses"
$downloadDir = Join-Path $repoRoot ".work\downloads"
$workRoot = Join-Path $repoRoot ".work\sensitive-content-$RuntimeVersion"
$stagingDir = Join-Path $workRoot "staging"
$distDir = Join-Path $workRoot "dist"
$buildDir = Join-Path $workRoot "build"
$smokeDir = Join-Path $workRoot "smoke"
$venvDir = Join-Path $repoRoot ".work\builder-venv"
$python = Join-Path $venvDir "Scripts\python.exe"
$packsDir = Join-Path $repoRoot "packs\sensitive-content"
$archiveName = "sensitive-content-windows-x86_64.zip"
$archivePath = Join-Path $packsDir $archiveName
$candidateManifestPath = Join-Path $repoRoot "manifests\sensitive-content.candidate.json"
$productionManifestPath = Join-Path $repoRoot "manifests\sensitive-content.json"
$registryPath = Join-Path $repoRoot "manifests\registry.json"
$checksumPath = Join-Path $repoRoot "checksums\SHA256SUMS.txt"
$releaseTag = "sensitive-content-$RuntimeVersion"
$packUrl = "https://github.com/$Owner/$Repo/releases/download/$releaseTag/$archiveName"

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $parent = Split-Path -Parent $Path
  if ($parent) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
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
  $client.Timeout = [TimeSpan]::FromMinutes(30)
  $client.DefaultRequestHeaders.UserAgent.ParseAdd("app-runtime-assets-sensitive-packager/1.0")
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

function Assert-QualificationForProduction {
  if ($definition.releaseEligible -ne $true) {
    throw "The selected model definition is candidate-only and cannot publish a production manifest."
  }
  if ($qualification.releaseGatePassed -ne $true) {
    throw "Qualification releaseGatePassed is not true."
  }
  if ([string]$qualification.commercialUseDecision -ne "approved") {
    throw "Qualification commercialUseDecision must be 'approved'."
  }
  if ($qualification.rightsAudit.modelWeightsApproved -ne $true -or
      $qualification.rightsAudit.trainingDataApproved -ne $true -or
      $qualification.rightsAudit.thirdPartyRuntimeApproved -ne $true -or
      [string]::IsNullOrWhiteSpace([string]$qualification.rightsAudit.reviewer)) {
    throw "Model, training-data and third-party runtime rights audits must all be approved by a named reviewer."
  }
  if ([string]$qualification.benchmarkReportSha256 -notmatch "^[a-f0-9]{64}$") {
    throw "Qualification benchmarkReportSha256 is missing or invalid."
  }
  if (@($qualification.licenseFiles).Count -eq 0) {
    throw "Qualification must list every approved full license file."
  }
  foreach ($license in $qualification.licenseFiles) {
    $relative = ([string]$license.path).Replace("/", "\")
    if ([System.IO.Path]::IsPathRooted($relative) -or $relative.Contains("..") -or $relative.Contains(":")) {
      throw "Qualification contains an unsafe license path: $relative"
    }
    $licensePath = [System.IO.Path]::GetFullPath((Join-Path $licensesSource $relative))
    $licenseRoot = [System.IO.Path]::GetFullPath($licensesSource)
    if (-not $licensePath.StartsWith($licenseRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $licensePath) -or
        (Get-Sha256 $licensePath) -ne ([string]$license.sha256).ToLowerInvariant()) {
      throw "Approved license file is missing or has the wrong SHA-256: $relative"
    }
  }
  if ($qualification.runtime.cpuQualified -ne $true) {
    throw "CPU runtime qualification is required."
  }
  foreach ($domain in @("live_action", "animation_game", "medical", "news", "sports")) {
    if ([int]$qualification.dataset.domains.$domain -le 0) {
      throw "Qualification dataset domain '$domain' is empty."
    }
  }
  foreach ($profileName in @("sensitive", "balanced", "low_false_positive")) {
    $profile = $qualification.profiles.$profileName
    foreach ($metric in @(
      "segmentPrecision",
      "segmentRecall",
      "falsePositiveMinutesPerHour",
      "falseNegativeEventRate",
      "boundaryLeadSecondsP95",
      "boundaryLagSecondsP95"
    )) {
      if ($null -eq $profile.$metric) {
        throw "Qualification metric '$profileName.$metric' is missing."
      }
    }
  }
}

if ($definition.schemaVersion -ne 1 -or $definition.bundleId -notmatch "^sensitive-content") {
  throw "Unsupported sensitive-content source definition."
}
if ($qualification.schemaVersion -ne 1) {
  throw "Unsupported qualification report schema."
}
if ($RuntimeVersion -notmatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$") {
  throw "RuntimeVersion contains unsupported characters."
}
if ($PublishManifest) {
  Assert-QualificationForProduction
}

New-Item -ItemType Directory -Force -Path $downloadDir, $packsDir | Out-Null
Reset-WorkDirectory $workRoot
New-Item -ItemType Directory -Force -Path $stagingDir, $distDir, $buildDir, $smokeDir | Out-Null

if (-not (Test-Path -LiteralPath $python)) {
  python -m venv $venvDir
  if ($LASTEXITCODE -ne 0) { throw "Could not create the isolated builder environment." }
}
$actualPythonVersion = @(& $python -c "import platform; print(platform.python_version())") | Select-Object -Last 1
if ([string]$actualPythonVersion -ne [string]$definition.builder.pythonVersion) {
  throw "Builder Python must be $($definition.builder.pythonVersion), got $actualPythonVersion. Remove .work/builder-venv and recreate it with the pinned interpreter."
}
& $python -m pip install --disable-pip-version-check --only-binary=:all: --require-hashes -r $requirements
if ($LASTEXITCODE -ne 0) { throw "Could not install pinned worker build dependencies." }

foreach ($model in $definition.models) {
  $expectedHash = ([string]$model.sha256).ToLowerInvariant()
  $expectedSize = [int64]$model.bytes
  if ($expectedHash -notmatch "^[a-f0-9]{64}$" -or $expectedSize -le 0) {
    throw "Model '$($model.id)' has invalid pinned integrity metadata."
  }
  $fileName = [System.IO.Path]::GetFileName([string]$model.packPath)
  $downloadPath = Join-Path $downloadDir $fileName
  $validExisting = (Test-Path -LiteralPath $downloadPath) -and
    ((Get-Item -LiteralPath $downloadPath).Length -eq $expectedSize) -and
    ((Get-Sha256 $downloadPath) -eq $expectedHash)
  if ($ForceDownload -or -not $validExisting) {
    Write-Host "Downloading pinned model $($model.id)..."
    Download-File -Url ([string]$model.url) -Destination $downloadPath
  }
  $actualSize = (Get-Item -LiteralPath $downloadPath).Length
  $actualHash = Get-Sha256 $downloadPath
  if ($actualSize -ne $expectedSize -or $actualHash -ne $expectedHash) {
    throw "Pinned model integrity mismatch for '$($model.id)'."
  }
}

& $python -m py_compile $workerSource
if ($LASTEXITCODE -ne 0) { throw "Worker Python syntax validation failed." }
& $python -m unittest discover -s $testsDir -v
if ($LASTEXITCODE -ne 0) { throw "Worker unit tests failed." }

$oldSourceDateEpoch = $env:SOURCE_DATE_EPOCH
$oldPythonHashSeed = $env:PYTHONHASHSEED
try {
  # PyInstaller uses these values for the Windows PE timestamp and Python hash
  # ordering. Together with the pinned interpreter/wheels they make repeated
  # builds from identical source byte-for-byte reproducible.
  $env:SOURCE_DATE_EPOCH = "946684800"
  $env:PYTHONHASHSEED = "1"
  & $python -m PyInstaller --noconfirm --clean --distpath $distDir --workpath $buildDir $workerSpec
  if ($LASTEXITCODE -ne 0) { throw "PyInstaller worker build failed." }
} finally {
  $env:SOURCE_DATE_EPOCH = $oldSourceDateEpoch
  $env:PYTHONHASHSEED = $oldPythonHashSeed
}
$workerDist = Join-Path $distDir "sensitive-content-worker"
$workerExe = Join-Path $workerDist "sensitive-content-worker.exe"
if (-not (Test-Path -LiteralPath $workerExe)) {
  throw "Built worker executable is missing."
}

New-Item -ItemType Directory -Force -Path `
  (Join-Path $stagingDir "bin"), `
  (Join-Path $stagingDir "models"), `
  (Join-Path $stagingDir "config"), `
  (Join-Path $stagingDir "metadata"), `
  (Join-Path $stagingDir "licenses") | Out-Null
Copy-Item -Path (Join-Path $workerDist "*") -Destination (Join-Path $stagingDir "bin") -Recurse -Force
# PyInstaller can carry pip's zero-byte REQUESTED marker. The application
# deliberately rejects zero-byte inventory entries, and this marker is not
# required at runtime.
Get-ChildItem -LiteralPath (Join-Path $stagingDir "bin") -Filter "REQUESTED" -File -Recurse |
  Where-Object { $_.Length -eq 0 -and $_.DirectoryName -like "*.dist-info" } |
  Remove-Item -Force
foreach ($model in $definition.models) {
  $fileName = [System.IO.Path]::GetFileName([string]$model.packPath)
  Copy-Item -LiteralPath (Join-Path $downloadDir $fileName) -Destination (Join-Path $stagingDir ([string]$model.packPath).Replace("/", "\")) -Force
}
Copy-Item -LiteralPath $calibrationSource -Destination (Join-Path $stagingDir "config\calibration.json") -Force
Copy-Item -LiteralPath $DefinitionPath -Destination (Join-Path $stagingDir "metadata\model-sources.json") -Force
Copy-Item -LiteralPath $QualificationReportPath -Destination (Join-Path $stagingDir "metadata\qualification.json") -Force
Copy-Item -Path (Join-Path $licensesSource "*") -Destination (Join-Path $stagingDir "licenses") -Recurse -Force

$thirdPartyNotice = @"
Bundled runtime dependencies
============================

Python 3.12 runtime: PSF License
NumPy 2.3.2: BSD-3-Clause
ONNX Runtime 1.22.1: MIT
PyInstaller 6.14.2 bootloader: GPL-2.0-or-later with the PyInstaller exception

The production release process must archive the corresponding full license
texts and legal review with the signed qualification record. This candidate
pack is blocked from production publication.
"@
Write-Utf8NoBom -Path (Join-Path $stagingDir "licenses\THIRD-PARTY-NOTICES.txt") -Content ($thirdPartyNotice.Trim() + "`n")

$modelHashMaterial = @()
foreach ($model in @($definition.models | Sort-Object id)) {
  $modelHashMaterial += "$($model.id):$(([string]$model.sha256).ToLowerInvariant())"
}
$modelHashMaterial += "calibration:$(Get-Sha256 $calibrationSource)"
$hashBytes = [System.Text.Encoding]::UTF8.GetBytes(($modelHashMaterial -join "`n"))
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
  $modelBundleHash = ([BitConverter]::ToString($sha.ComputeHash($hashBytes))).Replace("-", "").ToLowerInvariant()
} finally {
  $sha.Dispose()
}

$packMetadata = [ordered]@{
  schemaVersion = 1
  assetType = "sensitive-content"
  runtimeVersion = $RuntimeVersion
  modelBundleVersion = [string]$definition.bundleVersion
  modelBundleHash = $modelBundleHash
  calibrationVersion = [string](Get-Content -LiteralPath $calibrationSource -Raw | ConvertFrom-Json).calibrationVersion
  qualificationStatus = if ($PublishManifest) { "production_qualified" } else { "candidate_only" }
  workerFile = "bin/sensitive-content-worker.exe"
  provider = "cpu"
  offlineInference = $true
  audioDecode = $false
}
Write-Utf8NoBom -Path (Join-Path $stagingDir "pack.json") -Content (($packMetadata | ConvertTo-Json -Depth 10) + "`n")

$stagedWorker = Join-Path $stagingDir "bin\sensitive-content-worker.exe"
$healthOutput = @(& $stagedWorker --health-json 2>&1 | ForEach-Object { "$_" })
if ($LASTEXITCODE -ne 0) {
  throw "Built worker health check failed: $($healthOutput -join [Environment]::NewLine)"
}
$health = ($healthOutput -join "`n") | ConvertFrom-Json
if ($health.status -ne "ready" -or $health.schemaVersion -ne 1) {
  throw "Built worker returned an invalid health contract."
}

$ffmpegCommand = Get-Command ffmpeg -ErrorAction SilentlyContinue
if ($null -eq $ffmpegCommand) {
  throw "FFmpeg is required for the packaged worker smoke test."
}
$smokeVideo = Join-Path $smokeDir "safe-with-audio.mp4"
& $ffmpegCommand.Source -y -hide_banner -loglevel error `
  -f lavfi -i "testsrc2=size=320x180:rate=30:duration=2" `
  -f lavfi -i "sine=frequency=1000:duration=2" `
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest $smokeVideo
if ($LASTEXITCODE -ne 0) { throw "Could not create worker smoke fixture." }
$request = [ordered]@{
  schemaVersion = 1
  sourcePath = $smokeVideo
  sourceDuration = 2.0
  sourceFps = 30.0
  categories = [ordered]@{
    adult_nudity = $true
    blood_gore = $true
    violence_weapons = $false
  }
  sensitivity = "balanced"
} | ConvertTo-Json -Compress
$oldRoot = $env:SENSITIVE_CONTENT_RUNTIME_ROOT
$oldFfmpeg = $env:DOWNLOAD_MULTI_PLATFORM_FFMPEG
try {
  $env:SENSITIVE_CONTENT_RUNTIME_ROOT = $stagingDir
  $env:DOWNLOAD_MULTI_PLATFORM_FFMPEG = $ffmpegCommand.Source
  $analysisOutput = @($request | & $stagedWorker --analyze-jsonl 2>&1 | ForEach-Object { "$_" })
  if ($LASTEXITCODE -ne 0) {
    throw "Built worker analysis smoke failed: $($analysisOutput -join [Environment]::NewLine)"
  }
} finally {
  $env:SENSITIVE_CONTENT_RUNTIME_ROOT = $oldRoot
  $env:DOWNLOAD_MULTI_PLATFORM_FFMPEG = $oldFfmpeg
}
$terminalMessages = @($analysisOutput | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.type -in @("result", "error") })
if ($terminalMessages.Count -ne 1 -or $terminalMessages[0].type -ne "result") {
  throw "Built worker did not emit exactly one successful terminal message."
}
if (@($terminalMessages[0].result.segments).Count -ne 0) {
  throw "The deterministic safe smoke fixture produced a false-positive segment."
}

$files = @()
$stagingRoot = [System.IO.Path]::GetFullPath($stagingDir).TrimEnd("\", "/")
foreach ($file in @(Get-ChildItem -LiteralPath $stagingDir -File -Recurse | Sort-Object {
  $_.FullName.Substring($stagingRoot.Length + 1).Replace("\", "/")
})) {
  $relative = $file.FullName.Substring($stagingRoot.Length + 1).Replace("\", "/")
  $files += [ordered]@{
    path = $relative
    bytes = [int64]$file.Length
    sha256 = Get-Sha256 $file.FullName
  }
}

New-DeterministicZip -SourceDirectory $stagingDir -Destination $archivePath
$packSha256 = Get-Sha256 $archivePath
$manifest = [ordered]@{
  schemaVersion = 1
  assetType = "sensitive-content"
  runtimeVersion = $RuntimeVersion
  modelBundleVersion = [string]$definition.bundleVersion
  modelBundleHash = $modelBundleHash
  calibrationVersion = [string](Get-Content -LiteralPath $calibrationSource -Raw | ConvertFrom-Json).calibrationVersion
  qualificationStatus = if ($PublishManifest) { "production_qualified" } else { "candidate_only" }
  os = "windows"
  arch = "x86_64"
  installMode = "zip"
  packUrl = $packUrl
  packSha256 = $packSha256
  workerFile = "bin/sensitive-content-worker.exe"
  files = $files
  licenses = @(
    Get-ChildItem -LiteralPath (Join-Path $stagingDir "licenses") -File -Recurse |
      Sort-Object FullName |
      ForEach-Object {
        "licenses/" + $_.FullName.Substring((Join-Path $stagingDir "licenses").Length + 1).Replace("\", "/")
      }
  )
}
Write-Utf8NoBom -Path $candidateManifestPath -Content (($manifest | ConvertTo-Json -Depth 12) + "`n")

$checksumLine = "$packSha256  packs/sensitive-content/$archiveName"
$existing = @()
if (Test-Path -LiteralPath $checksumPath) {
  $escapedArchive = [regex]::Escape("packs/sensitive-content/$archiveName")
  $existing = @(Get-Content -LiteralPath $checksumPath | Where-Object {
    $_ -and ($_ -notmatch "$escapedArchive$")
  })
}
Write-Utf8NoBom -Path $checksumPath -Content ((@($existing + $checksumLine) -join "`n") + "`n")

if ($PublishManifest) {
  Copy-Item -LiteralPath $candidateManifestPath -Destination $productionManifestPath -Force
  $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
  $registry.updatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $entry = [ordered]@{
    manifestUrl = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch/manifests/sensitive-content.json"
    requiredBy = @("download-multi-platform")
    optional = $true
  }
  if ($registry.assets.PSObject.Properties["sensitive-content"]) {
    $registry.assets."sensitive-content" = $entry
  } else {
    $registry.assets | Add-Member -NotePropertyName "sensitive-content" -NotePropertyValue $entry
  }
  Write-Utf8NoBom -Path $registryPath -Content (($registry | ConvertTo-Json -Depth 10) + "`n")
}

Write-Host "Sensitive-content candidate package completed:"
Write-Host "  Runtime version:      $RuntimeVersion"
Write-Host "  Model bundle:         $($definition.bundleVersion)"
Write-Host "  Model bundle SHA-256: $modelBundleHash"
Write-Host "  Archive:              $archivePath"
Write-Host "  Archive size:         $((Get-Item -LiteralPath $archivePath).Length) bytes"
Write-Host "  Pack SHA-256:         $packSha256"
Write-Host "  Candidate manifest:   $candidateManifestPath"
Write-Host "  Production published: $([bool]$PublishManifest)"
if (-not $PublishManifest) {
  Write-Warning "Candidate only: production manifest and registry were intentionally not modified."
}
