# App Runtime Assets

Runtime asset registry used by DownloadMuliPlatform and future apps.

The app should hardcode only the registry URL:

```text
https://raw.githubusercontent.com/bahungbnck99/app-runtime-assets/main/manifests/registry.json
```

Each asset type has its own manifest and pack. The implemented asset types are
`fonts` and the Windows x64 `ffmpeg` runtime.

## Build FFmpeg Windows x64

The FFmpeg input is pinned by archive name, byte size, executable version,
and SHA-256 in:

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
- rejects a different archive or executable build using pinned version, size,
  and SHA-256 values;
- extracts only `ffmpeg.exe`, `ffprobe.exe`, and the upstream GPL license;
- verifies both executable versions and required filters/encoders;
- runs an H.264 encode/probe smoke test;
- creates a deterministic ZIP with fixed entry ordering and timestamps;
- updates `manifests/ffmpeg.json`, `manifests/registry.json`, and
  `checksums/SHA256SUMS.txt`.

The generated upload file is:

```text
packs/ffmpeg/ffmpeg-windows-x64-8.1-r1.zip
```

It is intentionally ignored by Git because its size exceeds GitHub's normal
Git file limit. Upload it to the GitHub Release tag
`ffmpeg-windows-x64-8.1-r1`. The manifest already uses the matching immutable
release URL.

The preserved source archive is intentionally local under `.work/downloads`
and is not committed. To rebuild, restore that verified archive or pass it
explicitly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/update-ffmpeg.ps1 `
  -UpstreamArchivePath C:\path\to\ffmpeg-master-20260610-preserved-win64-gpl.zip
```

The ZIP layout is:

```text
bin/
  ffmpeg.exe
  ffprobe.exe
LICENSES/
  FFmpeg-GPL-3.0.txt
  SOURCE-CODE.txt
BUILD-INFO.txt
PROVENANCE.json
pack.json
```

## Add Or Update Fonts

1. Copy font files into:

```text
sources/fonts/
```

Supported extensions: `.ttf`, `.otf`, `.ttc`, `.woff`, `.woff2`.

2. Optional: edit metadata in:

```text
sources/fonts.metadata.json
```

3. Run:

```powershell
powershell -ExecutionPolicy Bypass -File tools/update-fonts.ps1
```

Or pass an explicit version:

```powershell
powershell -ExecutionPolicy Bypass -File tools/update-fonts.ps1 -Version 2026.06.26
```

The script will:

- create `packs/fonts/fonts-pack-<version>.zip`
- update `manifests/fonts.json`
- update `manifests/registry.json`
- update `checksums/SHA256SUMS.txt`

4. Commit and push:

```powershell
git add .
git commit -m "Update runtime fonts"
git push origin main
```

## Zip Layout

The generated font zip contains:

```text
fonts/
  YourFont-Regular.ttf
  YourFont-Bold.ttf
licenses/
  Optional-LICENSE.txt
pack.json
```

The app installs the zip into:

```text
runtime/assets/fonts/current
```

## License Notes

License files are optional for internal use, but recommended for public GitHub storage,
especially for third-party fonts.

Đã tạo scaffold local cho repo runtime assets tại:

[app-runtime-assets](E:/extentions/app-runtime-assets)

Mình đã tạo cấu trúc:

```text
E:/extentions/app-runtime-assets/
  README.md
  .gitignore
  manifests/
    registry.json
    fonts.json
  packs/
    fonts/
  schemas/
    registry.schema.json
    asset-pack.schema.json
  checksums/
    SHA256SUMS.txt
  sources/
    fonts/
    licenses/
    fonts.metadata.json
  tools/
    update-fonts.ps1
```

Đã kiểm tra:
- PowerShell script syntax OK
- JSON manifest/schema parse OK

**Workflow Update Font**
Bạn thêm font vào:

```text
sources/fonts/
```

Ví dụ:

```text
sources/fonts/MyFont-Regular.ttf
sources/fonts/MyFont-Bold.ttf
```

Nếu có license thì thêm vào:

```text
sources/licenses/
```

Sau đó chạy:

```powershell
powershell -ExecutionPolicy Bypass -File tools/update-fonts.ps1
```

Hoặc chỉ định version:

```powershell
powershell -ExecutionPolicy Bypass -File tools/update-fonts.ps1 -Version 2026.06.26
```

Script sẽ tự động:
- nén font thành `packs/fonts/fonts-pack-<version>.zip`
- cập nhật `manifests/fonts.json`
- cập nhật `manifests/registry.json`
- cập nhật `checksums/SHA256SUMS.txt`
- tạo `pack.json` bên trong zip

`schemas/` là chuẩn định dạng cố định, không cần update mỗi lần thêm font.

**Plan App Runtime Fonts Cập Nhật**
1. App hardcode registry:
```text
https://raw.githubusercontent.com/bahungbnck99/app-runtime-assets/main/manifests/registry.json
```

2. Khi chưa install `App Fonts`:
- UI chỉ hiện font hệ thống mặc định.
- Native render dùng fallback như hiện tại.
- Preview dùng font system.

3. Khi user bấm install/update `App Fonts`:
- App đọc `registry.json`
- tải `fonts.json`
- tải zip theo `packUrl`
- verify `packSha256`
- extract vào staging
- validate font files trong manifest
- swap sang:
```text
runtime/assets/fonts/current
```

4. Sau khi install:
- Font dropdown hiển thị font runtime đã cài.
- Preview load font bằng `@font-face`.
- ASS subtitle render dùng `fontsdir`.
- Text layer render dùng `fontfile`.
- Template lưu font bằng ID ổn định.

5. Khi bạn cập nhật font mới lên repo:
- user bấm update
- app thấy `version/sha256` mới
- tải zip mới và activate
- không cần user cài font vào Windows.

Hiện mình mới scaffold repo `app-runtime-assets`, chưa push lên GitHub. Bước tiếp theo trong app chính là implement `App Fonts` runtime installer + font picker/render integration.
