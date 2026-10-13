from __future__ import annotations

import io
import zipfile
from pathlib import Path

from cursor_format import ROLES


PACKAGE_NAME = 'GraphitePearl'
PACKAGE_FILES = frozenset({
    'Apply.ps1', 'manifest.json', 'LICENSE', 'LICENSE-ASSETS.md',
    'THIRD_PARTY_NOTICES.md', 'preview.png', 'preview-actual.png',
    'animation-preview.gif',
} | {'cursors/'+role.file_name for role in ROLES})


def validate_package_files(package: Path, require_complete=True):
    """按白名单校验发布文件，排除本地备份。"""
    files = {}
    for path in package.rglob('*'):
        relative = path.relative_to(package)
        if '_备份' in relative.parts:
            continue
        if path.is_symlink():
            raise ValueError(f'发布目录不允许符号链接：{relative.as_posix()}')
        if path.is_file():
            files[relative.as_posix()] = path
    extra = set(files)-PACKAGE_FILES
    missing = PACKAGE_FILES-set(files) if require_complete else set()
    if extra or missing:
        details = []
        if extra:
            details.append('多余文件：'+', '.join(sorted(extra)))
        if missing:
            details.append('缺少文件：'+', '.join(sorted(missing)))
        raise ValueError('；'.join(details))
    return {name:files[name] for name in sorted(files)}


def build_archive(package: Path):
    """只打包已校验的白名单文件。"""
    files = validate_package_files(package)
    output = io.BytesIO()
    with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED) as archive:
        for name,path in files.items():
            archive.write(path,PACKAGE_NAME+'/'+name)
    return output.getvalue()
