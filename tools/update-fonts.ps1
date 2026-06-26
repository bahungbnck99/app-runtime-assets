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

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Read-U16BE([byte[]]$Bytes, [int]$Offset) {
  if ($Offset + 1 -ge $Bytes.Length) { return $null }
  return ((([int]$Bytes[$Offset]) -shl 8) -bor ([int]$Bytes[$Offset + 1]))
}

function Read-U32BE([byte[]]$Bytes, [int]$Offset) {
  if ($Offset + 3 -ge $Bytes.Length) { return $null }
  return ((([int]$Bytes[$Offset]) -shl 24) -bor (([int]$Bytes[$Offset + 1]) -shl 16) -bor (([int]$Bytes[$Offset + 2]) -shl 8) -bor ([int]$Bytes[$Offset + 3]))
}

function Decode-FontName([int]$PlatformId, [int]$EncodingId, [byte[]]$Raw) {
  if ($PlatformId -eq 0 -or $PlatformId -eq 3 -or $EncodingId -eq 1 -or $EncodingId -eq 10) {
    return ([System.Text.Encoding]::BigEndianUnicode.GetString($Raw)).Trim([char]0).Trim()
  }
  return ([System.Text.Encoding]::ASCII.GetString($Raw)).Trim([char]0).Trim()
}

function Get-FontNameScore($Record) {
  $platformScore = switch ($Record.platformId) {
    3 { 0 }
    0 { 10 }
    1 { 20 }
    default { 30 }
  }
  $languageScore = if ($Record.languageId -eq 0x0409 -or $Record.languageId -eq 0) { 0 } else { 1 }
  return $platformScore + $languageScore
}

function Get-BestFontName($Records, [int]$NameId) {
  $matches = @($Records | Where-Object { $_.nameId -eq $NameId })
  if ($matches.Count -eq 0) { return $null }
  return ($matches | Sort-Object @{ Expression = { Get-FontNameScore $_ } } | Select-Object -First 1).value
}

function Infer-RenderWeightStyle([string]$Descriptor, [int]$FallbackWeight, [string]$FallbackStyle) {
  $text = $Descriptor.ToLowerInvariant()
  $renderStyle = if ($text -match 'italic|oblique' -or $FallbackStyle -eq 'italic') { 'italic' } else { 'normal' }
  $renderWeight = $FallbackWeight
  if ($text -match 'thin') { $renderWeight = 100 }
  elseif ($text -match 'extra\s*light|ultra\s*light|extralight|ultralight') { $renderWeight = 200 }
  elseif ($text -match 'light') { $renderWeight = 300 }
  elseif ($text -match 'semi\s*bold|demi\s*bold|semibold|demibold') { $renderWeight = 600 }
  elseif ($text -match 'extra\s*bold|ultra\s*bold|extrabold|ultrabold') { $renderWeight = 800 }
  elseif ($text -match 'black|heavy') { $renderWeight = 900 }
  elseif ($text -match 'bold') { $renderWeight = 700 }
  elseif ($text -match 'medium') { $renderWeight = 500 }
  return [pscustomobject]@{ weight = $renderWeight; style = $renderStyle }
}

function Read-FontMetadata([string]$Path, [string]$FallbackFamily, [int]$FallbackWeight, [string]$FallbackStyle) {
  try {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $fontOffset = 0
    $tag = [System.Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(4, $bytes.Length))
    if ($tag -eq 'ttcf') {
      $fontOffset = Read-U32BE $bytes 12
    }
    $numTables = Read-U16BE $bytes ($fontOffset + 4)
    $nameOffset = $null
    for ($i = 0; $i -lt $numTables; $i++) {
      $recordOffset = $fontOffset + 12 + ($i * 16)
      $tableTag = [System.Text.Encoding]::ASCII.GetString($bytes, $recordOffset, 4)
      if ($tableTag -eq 'name') {
        $nameOffset = Read-U32BE $bytes ($recordOffset + 8)
        break
      }
    }
    if ($null -eq $nameOffset) { throw "Font has no name table" }
    $count = Read-U16BE $bytes ($nameOffset + 2)
    $stringOffset = Read-U16BE $bytes ($nameOffset + 4)
    $records = @()
    for ($i = 0; $i -lt $count; $i++) {
      $recordOffset = $nameOffset + 6 + ($i * 12)
      $platformId = Read-U16BE $bytes $recordOffset
      $encodingId = Read-U16BE $bytes ($recordOffset + 2)
      $languageId = Read-U16BE $bytes ($recordOffset + 4)
      $nameId = Read-U16BE $bytes ($recordOffset + 6)
      $length = Read-U16BE $bytes ($recordOffset + 8)
      $offset = Read-U16BE $bytes ($recordOffset + 10)
      $start = $nameOffset + $stringOffset + $offset
      if ($start + $length -gt $bytes.Length) { continue }
      $raw = New-Object byte[] $length
      [Array]::Copy($bytes, $start, $raw, 0, $length)
      $value = Decode-FontName $platformId $encodingId $raw
      if ([string]::IsNullOrWhiteSpace($value)) { continue }
      $records += [pscustomobject]@{
        nameId = $nameId
        platformId = $platformId
        languageId = $languageId
        value = $value
      }
    }
    $family = Get-BestFontName $records 16
    if ([string]::IsNullOrWhiteSpace($family)) { $family = Get-BestFontName $records 1 }
    if ([string]::IsNullOrWhiteSpace($family)) { $family = $FallbackFamily }
    $subfamily = Get-BestFontName $records 17
    if ([string]::IsNullOrWhiteSpace($subfamily)) { $subfamily = Get-BestFontName $records 2 }
    $fullName = Get-BestFontName $records 4
    $postScriptName = Get-BestFontName $records 6
    $shape = Infer-RenderWeightStyle "$subfamily $family $fullName $postScriptName" $FallbackWeight $FallbackStyle
    return [pscustomobject]@{
      family = $family
      weight = [int]$shape.weight
      style = $shape.style
      fullName = $fullName
      postScriptName = $postScriptName
    }
  } catch {
    return [pscustomobject]@{
      family = $FallbackFamily
      weight = $FallbackWeight
      style = $FallbackStyle
      fullName = $null
      postScriptName = $null
    }
  }
}

$fontFiles = Get-ChildItem -Path $sourceFontsDir -File -Recurse |
  Where-Object { $_.Extension.ToLowerInvariant() -in @(".ttf", ".otf", ".ttc", ".otc") } |
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
  $render = Read-FontMetadata $font.FullName $family $weight $style

  $items += [ordered]@{
    id = $id
    family = $family
    weight = $weight
    style = $style
    file = $relativeFile
    renderFamily = $render.family
    renderWeight = [int]$render.weight
    renderStyle = $render.style
    fullName = $render.fullName
    postScriptName = $render.postScriptName
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
Write-Utf8NoBom -Path (Join-Path $workDir "pack.json") -Content ($packJson | ConvertTo-Json -Depth 10)

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
Write-Utf8NoBom -Path (Join-Path $manifestsDir "fonts.json") -Content ($fontsManifest | ConvertTo-Json -Depth 10)

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
Write-Utf8NoBom -Path (Join-Path $manifestsDir "registry.json") -Content ($registry | ConvertTo-Json -Depth 10)

$checksumLine = "$zipSha256  packs/fonts/fonts-pack-$Version.zip"
$existing = @()
$checksumPath = Join-Path $checksumsDir "SHA256SUMS.txt"
if (Test-Path $checksumPath) {
  $existing = Get-Content -LiteralPath $checksumPath | Where-Object { $_ -and ($_ -notmatch "packs/fonts/fonts-pack-$Version\.zip$") }
}
Write-Utf8NoBom -Path $checksumPath -Content (@($existing + $checksumLine) -join [Environment]::NewLine)

Write-Host "Updated runtime font pack:"
Write-Host "  Version: $Version"
Write-Host "  Fonts:   $($fontFiles.Count)"
Write-Host "  Zip:     $zipPath"
Write-Host "  SHA256:  $zipSha256"
