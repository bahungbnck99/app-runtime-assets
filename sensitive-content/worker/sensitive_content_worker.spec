# -*- mode: python ; coding: utf-8 -*-

from pathlib import Path

project_root = Path(SPEC).resolve().parents[2]
worker = project_root / "sensitive-content" / "worker" / "sensitive_content_worker.py"

a = Analysis(
    [str(worker)],
    pathex=[str(worker.parent)],
    binaries=[],
    datas=[],
    hiddenimports=["onnxruntime.capi._pybind_state"],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["onnx", "PIL", "tkinter"],
    noarchive=False,
    optimize=1,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="sensitive-content-worker",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="sensitive-content-worker",
)
