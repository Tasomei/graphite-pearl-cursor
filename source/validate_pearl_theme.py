from __future__ import annotations

import ast
import hashlib
import io
import json
import re
import tokenize
import zipfile
from pathlib import Path

from PIL import ImageChops, ImageOps

from build_pearl_theme import ANIMATED_SIZES, PACKAGE, ROOT, ani_frames, decode
from cursor_format import ANIMATION_FRAMES, CURSOR_SIZES, ROLES, native_check
from pearl_artwork import ASSETS, POINTER_MASTER, hotspots, render_pearl
from package_layout import PACKAGE_FILES, PACKAGE_NAME, validate_package_files


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    validate_package_files(PACKAGE)
    manifest = json.loads((PACKAGE/'manifest.json').read_text(encoding='utf-8'))
    assert manifest['version'] == (ROOT/'VERSION').read_text(encoding='utf-8').strip()
    expected = {role.key:role for role in ROLES}
    assert len(manifest['roles']) == len(expected) == 17
    assert {item['role'] for item in manifest['roles']} == set(expected)
    for item in manifest['roles']:
        role = expected[item['role']]
        assert item['file'] == 'cursors/'+role.file_name
        assert item['animated'] == role.animated
        path = PACKAGE/item['file']
        data = path.read_bytes()
        assert digest(data) == item['sha256'],role.key
        sizes = ANIMATED_SIZES if role.animated else CURSOR_SIZES
        assert item['sizes'] == list(sizes)
        hotspot = hotspots().get(role.key,(64,64))
        assert list(hotspot) == item['hotspot_logical_128']
        frames = ani_frames(data) if role.animated else [data]
        signatures = {size:set() for size in sizes}
        for index,frame in enumerate(frames):
            images,actual_hotspots = decode(frame,sizes,hotspot)
            assert {str(size):list(point) for size,point in actual_hotspots.items()} == item['hotspots']
            for size,image in images.items():
                assert image.tobytes() == render_pearl(role.key,size,index/ANIMATION_FRAMES).tobytes()
                signatures[size].add(digest(image.tobytes()))
        assert all(len(values) == len(frames) for values in signatures.values())
        native_check(path,actual_hotspots)
    assert (PACKAGE/'cursors/link.cur').read_bytes() == (PACKAGE/'cursors/alternate.cur').read_bytes()
    for size in CURSOR_SIZES:
        alpha = render_pearl('link',size).getchannel('A')
        assert ImageChops.difference(alpha,ImageOps.mirror(alpha)).getbbox() is None
    assets = {'arrow':POINTER_MASTER}
    assets.update({path.stem:path for path in (ASSETS/'pearl').glob('*.png')})
    assert manifest['source_assets'] == {key:digest(path.read_bytes()) for key,path in assets.items()}
    installer = (PACKAGE/'Apply.ps1').read_bytes()
    assert installer.startswith(b'\xef\xbb\xbf') and not installer.startswith(b'\xef\xbb\xbf'*2)
    assert (PACKAGE/'Apply.ps1').read_text(encoding='utf-8-sig') == (ROOT/'source/apply_pearl_theme.ps1').read_text(encoding='utf-8-sig')
    with zipfile.ZipFile(ROOT/'Graphite-Pearl-Cursor-Windows.zip') as archive:
        assert archive.testzip() is None
        files = {PACKAGE_NAME+'/'+name for name in PACKAGE_FILES}
        assert len(archive.namelist()) == len(files) and set(archive.namelist()) == files
        for name in archive.namelist():
            assert '_备份' not in name
            assert archive.read(name) == (PACKAGE.parent/name).read_bytes()
    for path in (ROOT/'source').glob('*.ps1'):
        assert path.read_bytes().startswith(b'\xef\xbb\xbf'),path.name
    for path in (ROOT/'source').glob('*.py'):
        source = path.read_text(encoding='utf-8')
        tree = ast.parse(source)
        comments = [token.string for token in tokenize.generate_tokens(io.StringIO(source).readline) if token.type == tokenize.COMMENT]
        for node in ast.walk(tree):
            if isinstance(node,(ast.Module,ast.ClassDef,ast.FunctionDef,ast.AsyncFunctionDef)):
                doc = ast.get_docstring(node)
                if doc:
                    comments.append(doc)
        assert all(re.search(r'[\u4e00-\u9fff]',text) and len(text)<=40 for text in comments),path.name
    print('PASS: 17 roles, pixels, hotspots, animation, native loading and symmetry')
    print('PASS: source hashes, installer, archive contents and concise Chinese comments')


if __name__ == '__main__':
    main()
