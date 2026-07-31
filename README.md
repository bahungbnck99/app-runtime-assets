# App Runtime Assets

Runtime asset registry used by DownloadMuliPlatform and future apps.

The app hardcodes only this registry URL:

```text
https://raw.githubusercontent.com/bahungbnck99/app-runtime-assets/main/manifests/registry.json
```

Each asset type has its own manifest and pack. The production asset types are
`fonts` and the Windows x64 `ffmpeg` runtime. This repository also contains
the fail-closed Windows x64 sensitive-content worker project and a candidate
model bundle used for engineering qualification.

## Sensitive-content Windows x64

The sensitive-content project provides:

- an offline JSONL worker using ONNX Runtime CPU;
- coarse/refine FFmpeg scanning with audio, subtitle and data decode disabled;
- separate image and temporal inference branches;
- calibrated blood/gore fusion using NSFL, static/temporal violence context
  and bounded localized dark-red evidence;
- bounded progress/result output compatible with DownloadMuliPlatform;
- pinned model revision, byte-size and SHA-256 definitions;
- a deterministic archive layout, complete content-hashed file inventory and verifier;
- a production release gate covering rights, calibration, benchmarks and
  runtime qualification.

Build the local candidate:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File tools/update-sensitive-content.ps1 `
  -RuntimeVersion 1.0.0-candidate.2
```

Verify the exact ZIP and manifest independently:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File tools/verify-sensitive-content.ps1
```

Outputs:

```text
packs/sensitive-content/sensitive-content-windows-x86_64.zip
manifests/sensitive-content.candidate.json
checksums/SHA256SUMS.txt
```

The ZIP is intentionally ignored by Git and is suitable for local engineering
tests. The candidate manifest is not registered by the application. Current
candidate checkpoints have declared weight licenses, but their model cards do
not provide sufficient training-data rights evidence or the required
cross-domain qualification data. The build therefore cannot accidentally
create `manifests/sensitive-content.json` or modify the registry.

To promote a future rights-cleared model bundle:

1. Add a pinned model definition with `releaseEligible: true`.
2. Complete a qualification report with a commercial-use decision, non-empty
   live-action/animation-game/medical/news/sports sets, all profile metrics and
   CPU qualification.
3. Build with explicit production inputs:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File tools/update-sensitive-content.ps1 `
  -RuntimeVersion 1.0.0 `
  -DefinitionPath sources/sensitive-content-production-1.0.0.json `
  -QualificationReportPath sensitive-content/qualification/qualification-1.0.0.json `
  -PublishManifest
```

4. Run the independent verifier.
5. Upload the exact ZIP to release tag `sensitive-content-1.0.0`, then commit
   the generated production manifest, registry and checksum.

The manual GitHub Actions workflow
`.github/workflows/build-sensitive-content.yml` performs the same build and
verification. Set `publish_candidate_release` to create a clearly marked
GitHub prerelease for engineering tests without changing the production
registry. It only creates a production GitHub Release and publishes registry
metadata when `publish_production` is explicitly enabled and every release
gate passes.

The cross-domain evaluator accepts a rights-cleared JSONL index based on
`sensitive-content/qualification/dataset-index.example.jsonl`. Run it against
an extracted candidate or production runtime:

```powershell
python sensitive-content/qualification/evaluate.py `
  --worker .work/runtime/bin/sensitive-content-worker.exe `
  --runtime-root .work/runtime `
  --ffmpeg C:\path\to\ffmpeg.exe `
  --dataset-index C:\qualification\dataset-index.jsonl `
  --output .work/qualification-metrics.json
```

It verifies every source SHA-256 and calculates temporal precision/recall,
false-positive minutes/hour, false-negative event rate and boundary lead/lag
for every sensitivity profile and category. Metric generation never flips the
production release gate; rights and runtime approvals remain explicit.

## Build FFmpeg Windows x64

The FFmpeg input is pinned by archive name, byte size, executable version and
SHA-256 in:

```text
sources/ffmpeg-windows-x64-8.1-r1.json
```

Build the release artifact with Windows PowerShell 5.1 or newer:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/update-ffmpeg.ps1
```

The current `8.1-r1` package preserves the known-good BtbN master build
`N-124941-g54749da98a-20260610` used by the application. The release tag and
asset name remain unchanged for compatibility.

The workflow:

- loads the pinned preserved BtbN GPL static Windows x64 archive;
- rejects a different archive or executable build using pinned version, size
  and SHA-256 values;
- extracts only `ffmpeg.exe`, `ffprobe.exe` and the upstream GPL license;
- verifies both executable versions and required filters/encoders;
- runs an H.264 encode/probe smoke test;
- creates a deterministic ZIP with fixed entry ordering and timestamps;
- updates the FFmpeg manifest, registry and checksum list.

The generated upload file is:

```text
packs/ffmpeg/ffmpeg-windows-x64-8.1-r1.zip
```

It is intentionally ignored by Git because its size exceeds GitHub's normal
Git file limit. Upload it to release tag `ffmpeg-windows-x64-8.1-r1`.

The preserved source archive is local under `.work/downloads`. To rebuild,
restore that verified archive or pass it explicitly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File tools/update-ffmpeg.ps1 `
  -UpstreamArchivePath C:\path\to\ffmpeg-master-20260610-preserved-win64-gpl.zip
```

## Add or update fonts

1. Copy `.ttf`, `.otf`, `.ttc`, `.woff` or `.woff2` files into
   `sources/fonts/`.
2. Optionally edit `sources/fonts.metadata.json`.
3. Run:

```powershell
powershell -ExecutionPolicy Bypass -File tools/update-fonts.ps1
```

Or pass an explicit version:

```powershell
powershell -ExecutionPolicy Bypass `
  -File tools/update-fonts.ps1 `
  -Version 2026.06.26
```

The script creates `packs/fonts/fonts-pack-<version>.zip` and updates the font
manifest, registry and checksum list. Include third-party font license files
before publishing a public pack.
