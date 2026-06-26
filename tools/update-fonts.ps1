param(
  [string]$Version = (Get-Date -Format "yyyy.MM.dd"),
  [string]$Owner = "bahungbnck99",
  [string]$Repo = "app-runtime-assets",
  [string]$Branch = "main"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$sourceFontsDir = Join-Path $repoRoot "sources\fonts"
$sourceLicensesDir = Join-Path $repoRoot "sources\licenses"
$metadataPath = Join-Path $repoRoot "sources\fonts.metadata.json"
$packsDir = Join-Path $repoRoot "packs\fonts"
$manifestsDir = Join-Path $repoRoot "manifests"
$checksumsDir = Join-Path $repoRoot "checksums"
$workDir = Join-Path $repoRoot ".work\fonts-pack-$Version"
$zipPath = Join-Path $packsDir "fonts-pack-$Version.zip"

New-Item -ItemType Directory -Force -Path $sourceFontsDir, $packsDir, $manifestsDir, $checksumsDir | Out-Null

$fontFiles = Get-ChildItem -Path $sourceFontsDir -File -Recurse |
  Where-Object { $_.Extension.ToLowerInvariant() -in @(".ttf", ".otf", ".ttc", ".woff", ".woff2") } |
  Sort-Object FullName

if ($fontFiles.Count -eq 0) {
  throw "No font files found in $sourceFontsDir"
}

if (Test-Path $workDir) {
  Remove-Item -LiteralPath $workDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path (Join-Path $workDir "fonts") | Out-Null

foreach ($font in $fontFiles) {
  Copy-Item -LiteralPath $font.FullName -Destination (Join-Path $workDir "fonts\$($font.Name)") -Force
}

if (Test-Path $sourceLicensesDir) {
  $licenseFiles = Get-ChildItem -Path $sourceLicensesDir -File -Recurse
  if ($licenseFiles.Count -gt 0) {
    New-Item -ItemType Directory -Force -Path (Join-Path $workDir "licenses") | Out-Null
    foreach ($license in $licenseFiles) {
      Copy-Item -LiteralPath $license.FullName -Destination (Join-Path $workDir "licenses\$($license.Name)") -Force
    }
  }
}

$metadata = [pscustomobject]@{
  defaults = [pscustomobject]@{
    license = ""
    apps = @("download-multi-platform", "*")
  }
  fonts = [pscustomobject]@{}
}
if (Test-Path $metadataPath) {
  $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
}

function New-FontId([string]$fileName) {
  $name = [System.IO.Path]::GetFileNameWithoutExtension($fileName).ToLowerInvariant()
  $name = $name -replace '[^a-z0-9]+', '-'
  $name.Trim('-')
}

function Guess-FontWeight([string]$fileName) {
  $name = $fileName.ToLowerInvariant()
  if ($name -match 'thin') { return 100 }
  if ($name -match 'extra.?light|ultra.?light') { return 200 }
  if ($name -match 'light') { return 300 }
  if ($name -match 'medium') { return 500 }
  if ($name -match 'semi.?bold|demi.?bold') { return 600 }
  if ($name -match 'extra.?bold|ultra.?bold') { return 800 }
  if ($name -match 'black|heavy') { return 900 }
  if ($name -match 'bold') { return 700 }
  return 400
}

function Guess-FontStyle([string]$fileName) {
  if ($fileName.ToLowerInvariant() -match 'italic|oblique') {
    return "italic"
  }
  return "normal"
}

function Guess-FontFamily([string]$fileName) {
  $name = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
  $name = $name -replace '[-_ ]?(Thin|ExtraLight|UltraLight|Light|Regular|Medium|SemiBold|DemiBold|Bold|ExtraBold|UltraBold|Black|Heavy|Italic|Oblique)$', ''
  $name = $name -replace '[-_]+', ' '
  if ([string]::IsNullOrWhiteSpace($name)) {
    return [System.IO.Path]::GetFileNameWithoutExtension($fileName)
  }
  return $name.Trim()
}

$items = @()
$packItems = @()
foreach ($font in $fontFiles) {
  $relativeFile = "fonts/$($font.Name)"
  $fontKey = $font.Name
  $override = $null
  if ($metadata.fonts -and $metadata.fonts.PSObject.Properties[$fontKey]) {
    $override = $metadata.fonts.PSObject.Properties[$fontKey].Value
  }
  $id = if ($override -and $override.id) { $override.id } else { New-FontId $font.Name }
  $family = if ($override -and $override.family) { $override.family } else { Guess-FontFamily $font.Name }
  $weight = if ($override -and $override.weight) { [int]$override.weight } else { Guess-FontWeight $font.Name }
  $style = if ($override -and $override.style) { $override.style } else { Guess-FontStyle $font.Name }
  $license = if ($override -and $override.license) { $override.license } else { $metadata.defaults.license }

  $items += [ordered]@{
    id = $id
    family = $family
    weight = $weight
    style = $style
    file = $relativeFile
    license = $license
  }
  $fileHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $font.FullName).Hash.ToLowerInvariant()
  $packItems += [ordered]@{
    id = $id
    file = $relativeFile
    sha256 = $fileHash
  }
}

$packJson = [ordered]@{
  schemaVersion = 1
  assetType = "fonts"
  version = $Version
  items = $packItems
}
$packJson | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $workDir "pack.json") -Encoding UTF8

if (Test-Path $zipPath) {
  Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -Path (Join-Path $workDir "*") -DestinationPath $zipPath -CompressionLevel Optimal

$zipSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
$packUrl = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch/packs/fonts/fonts-pack-$Version.zip"

$fontsManifest = [ordered]@{
  schemaVersion = 1
  assetType = "fonts"
  version = $Version
  channel = "stable"
  installMode = "zip"
  packUrl = $packUrl
  packSha256 = $zipSha256
  installDir = "fonts"
  apps = @($metadata.defaults.apps)
  items = $items
}
$fontsManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $manifestsDir "fonts.json") -Encoding UTF8

$registry = [ordered]@{
  schemaVersion = 1
  updatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  publisher = $Owner
  assets = [ordered]@{
    fonts = [ordered]@{
      manifestUrl = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch/manifests/fonts.json"
      requiredBy = @("download-multi-platform")
      optional = $false
    }
  }
}
$registry | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $manifestsDir "registry.json") -Encoding UTF8

$checksumLine = "$zipSha256  packs/fonts/fonts-pack-$Version.zip"
$existing = @()
$checksumPath = Join-Path $checksumsDir "SHA256SUMS.txt"
if (Test-Path $checksumPath) {
  $existing = Get-Content -LiteralPath $checksumPath | Where-Object { $_ -and ($_ -notmatch "packs/fonts/fonts-pack-$Version\.zip$") }
}
@($existing + $checksumLine) | Set-Content -LiteralPath $checksumPath -Encoding UTF8

Write-Host "Updated runtime font pack:"
Write-Host "  Version: $Version"
Write-Host "  Fonts:   $($fontFiles.Count)"
Write-Host "  Zip:     $zipPath"
Write-Host "  SHA256:  $zipSha256"
