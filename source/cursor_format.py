from __future__ import annotations

import ctypes
import io
import struct
from ctypes import wintypes
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageFont


LOGICAL_SIZE = 128
CURSOR_SIZES = (32, 48, 64, 96, 128)
ANIMATION_FRAMES = 12
ANIMATION_JIFFIES = 4


@dataclass(frozen=True)
class Role:
    key: str
    label_zh: str
    file_name: str
    hotspot: tuple[float, float]
    animated: bool = False


ROLES = (
    Role("arrow", "正常选择", "arrow.cur", (64, 64)),
    Role("help", "帮助选择", "help.cur", (64, 64)),
    Role("working", "后台工作", "working.ani", (64, 64), True),
    Role("busy", "忙碌", "busy.ani", (64, 64), True),
    Role("precision", "精确选择", "precision.cur", (64, 64)),
    Role("text", "文本选择", "text.cur", (64, 64)),
    Role("handwriting", "手写", "handwriting.cur", (64, 64)),
    Role("unavailable", "不可用", "unavailable.cur", (64, 64)),
    Role("vertical", "垂直调整", "vertical.cur", (64, 64)),
    Role("horizontal", "水平调整", "horizontal.cur", (64, 64)),
    Role("diagonal_nwse", "对角调整 1", "diagonal_nwse.cur", (64, 64)),
    Role("diagonal_nesw", "对角调整 2", "diagonal_nesw.cur", (64, 64)),
    Role("move", "移动", "move.cur", (64, 64)),
    Role("alternate", "候选选择", "alternate.cur", (64, 64)),
    Role("link", "链接选择", "link.cur", (64, 64)),
    Role("location", "位置选择", "location.cur", (64, 64)),
    Role("person", "人员选择", "person.cur", (64, 64)),
)


def dib_payload(image: Image.Image) -> bytes:
    image = image.convert("RGBA")
    width, height = image.size
    bgra = image.tobytes("raw", "BGRA")
    row_bytes = width * 4
    pixels = b"".join(
        bgra[row * row_bytes : (row + 1) * row_bytes]
        for row in range(height - 1, -1, -1)
    )

    mask_stride = ((width + 31) // 32) * 4
    alpha = image.getchannel("A")
    mask_rows: list[bytes] = []
    for y in range(height - 1, -1, -1):
        row = bytearray(mask_stride)
        for x in range(width):
            if alpha.getpixel((x, y)) < 16:
                row[x // 8] |= 0x80 >> (x % 8)
        mask_rows.append(bytes(row))
    mask = b"".join(mask_rows)
    image_size = len(pixels) + len(mask)
    header = struct.pack(
        "<IiiHHIIiiII",
        40,
        width,
        height * 2,
        1,
        32,
        0,
        image_size,
        0,
        0,
        0,
        0,
    )
    return header + pixels + mask


def build_cur_bytes(images: dict[int, Image.Image], hotspot: tuple[float, float]) -> bytes:
    payloads: list[tuple[int, int, int, int, bytes]] = []
    for size in sorted(images):
        hot_x = min(size - 1, max(0, round(hotspot[0] * size / LOGICAL_SIZE)))
        hot_y = min(size - 1, max(0, round(hotspot[1] * size / LOGICAL_SIZE)))
        payloads.append((size, size, hot_x, hot_y, dib_payload(images[size])))

    header = struct.pack("<HHH", 0, 2, len(payloads))
    offset = 6 + 16 * len(payloads)
    entries = bytearray()
    data = bytearray()
    for width, height, hot_x, hot_y, payload in payloads:
        width_byte = 0 if width >= 256 else width
        height_byte = 0 if height >= 256 else height
        entries.extend(
            struct.pack(
                "<BBBBHHII",
                width_byte,
                height_byte,
                0,
                0,
                hot_x,
                hot_y,
                len(payload),
                offset,
            )
        )
        data.extend(payload)
        offset += len(payload)
    return header + bytes(entries) + bytes(data)


def riff_chunk(chunk_id: bytes, data: bytes) -> bytes:
    padding = b"\x00" if len(data) % 2 else b""
    return chunk_id + struct.pack("<I", len(data)) + data + padding


def build_ani_bytes(frames: list[bytes]) -> bytes:
    frame_count = len(frames)
    anih = struct.pack(
        "<9I",
        36,
        frame_count,
        frame_count,
        0,
        0,
        32,
        1,
        ANIMATION_JIFFIES,
        1,
    )
    rate = struct.pack(f"<{frame_count}I", *([ANIMATION_JIFFIES] * frame_count))
    frame_list = b"fram" + b"".join(riff_chunk(b"icon", frame) for frame in frames)
    body = riff_chunk(b"anih", anih) + riff_chunk(b"rate", rate) + riff_chunk(b"LIST", frame_list)
    return b"RIFF" + struct.pack("<I", len(body) + 4) + b"ACON" + body


def find_preview_font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = (
        Path("C:/Windows/Fonts/msyhbd.ttc") if bold else Path("C:/Windows/Fonts/msyh.ttc"),
        Path("C:/Windows/Fonts/seguisb.ttf") if bold else Path("C:/Windows/Fonts/segoeui.ttf"),
    )
    for candidate in candidates:
        if candidate.exists():
            return ImageFont.truetype(str(candidate), size)
    return ImageFont.load_default()


class IconInfo(ctypes.Structure):
    _fields_ = [('fIcon',wintypes.BOOL), ('xHotspot',wintypes.DWORD),
                ('yHotspot',wintypes.DWORD), ('hbmMask',wintypes.HBITMAP), ('hbmColor',wintypes.HBITMAP)]


class Bitmap(ctypes.Structure):
    _fields_ = [('bmType',wintypes.LONG), ('bmWidth',wintypes.LONG), ('bmHeight',wintypes.LONG),
                ('bmWidthBytes',wintypes.LONG), ('bmPlanes',wintypes.WORD), ('bmBitsPixel',wintypes.WORD), ('bmBits',ctypes.c_void_p)]


def native_check(path, hotspots):
    """验证原生加载，不切换系统光标。"""
    user32 = ctypes.WinDLL('user32',use_last_error=True)
    gdi32 = ctypes.WinDLL('gdi32',use_last_error=True)
    user32.LoadImageW.argtypes = [wintypes.HINSTANCE,wintypes.LPCWSTR,wintypes.UINT,ctypes.c_int,ctypes.c_int,wintypes.UINT]
    user32.LoadImageW.restype = wintypes.HANDLE
    user32.GetIconInfo.argtypes = [wintypes.HANDLE,ctypes.POINTER(IconInfo)]
    user32.DestroyCursor.argtypes = [wintypes.HANDLE]
    gdi32.GetObjectW.argtypes = [wintypes.HANDLE,ctypes.c_int,ctypes.c_void_p]
    gdi32.DeleteObject.argtypes = [wintypes.HANDLE]
    for size,hotspot in hotspots.items():
        cursor = user32.LoadImageW(None,str(path),2,size,size,0x10)
        if not cursor:
            raise ctypes.WinError(ctypes.get_last_error())
        info = IconInfo()
        try:
            assert user32.GetIconInfo(cursor,ctypes.byref(info))
            assert not info.fIcon and (info.xHotspot,info.yHotspot) == hotspot
            bitmap = Bitmap()
            assert gdi32.GetObjectW(info.hbmColor,ctypes.sizeof(bitmap),ctypes.byref(bitmap))
            assert (bitmap.bmWidth,bitmap.bmHeight) == (size,size)
        finally:
            for handle in (info.hbmMask,info.hbmColor):
                if handle:
                    assert gdi32.DeleteObject(handle)
            assert user32.DestroyCursor(cursor)


def png_bytes(image):
    buffer = io.BytesIO()
    image.save(buffer,format='PNG')
    return buffer.getvalue()
