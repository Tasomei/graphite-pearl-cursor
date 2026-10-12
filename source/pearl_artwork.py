from __future__ import annotations

import math
from functools import lru_cache
from pathlib import Path

from PIL import Image, ImageChops, ImageFilter, ImageOps


ASSETS = Path(__file__).resolve().parent / 'assets'
POINTER_SPAN = 46.8
POINTER_ANGLE = 33.0
SCALE_REFERENCE_ANGLE = 42.95
POINTER_MASTER = ASSETS/'pearl-pointer-symmetric-up.png'
SPANS = {
    'busy':55.8, 'precision':57.6, 'text':57.6,
    'handwriting':50.4, 'unavailable':55.8, 'horizontal':59.4,
    'move':57.6, 'location':57.6, 'person':55.8,
}


def remove_speckles(image):
    """保留主体连通区和透明边缘。"""
    alpha = image.getchannel('A')
    ratio = min(1,384/max(image.size))
    size = tuple(max(1,round(v*ratio)) for v in image.size)
    small = alpha.resize(size,Image.Resampling.LANCZOS)
    bits = bytearray(1 if v>=64 else 0 for v in small.tobytes())
    width,height = size
    components = []
    for start in range(len(bits)):
        if not bits[start]:
            continue
        bits[start] = 0
        pending,component = [start],[]
        while pending:
            point = pending.pop()
            component.append(point)
            x,y = point%width,point//width
            for nx,ny in ((x-1,y),(x+1,y),(x,y-1),(x,y+1)):
                if 0<=nx<width and 0<=ny<height:
                    neighbor = ny*width+nx
                    if bits[neighbor]:
                        bits[neighbor] = 0
                        pending.append(neighbor)
        components.append(component)
    if not components:
        raise ValueError('素材主体为空')
    largest = max(map(len,components))
    keep = bytearray(len(bits))
    for component in components:
        if len(component)>=largest*.04:
            for point in component:
                keep[point] = 255
    mask = Image.frombytes('L',size,bytes(keep)).filter(ImageFilter.MaxFilter(9))
    mask = mask.resize(image.size,Image.Resampling.LANCZOS)
    result = image.copy()
    result.putalpha(ImageChops.multiply(alpha,mask))
    return result


@lru_cache(maxsize=16)
def master(key):
    path = POINTER_MASTER if key=='arrow' else ASSETS/'pearl'/f'{key}.png'
    with Image.open(path) as source:
        if source.mode!='RGBA':
            raise ValueError(f'素材缺少透明通道：{key}')
        image = source.copy()
    assert image.getchannel('A').getextrema() == (0,255)
    return image if key=='arrow' else remove_speckles(image)


def core_box(image):
    box = image.getchannel('A').point(lambda v:255 if v>=192 else 0).getbbox()
    if box is None:
        raise ValueError('光标主体为空')
    return box


@lru_cache(maxsize=64)
def layer(key, span, center=(64,64), angle=0):
    """统一可见尺寸，旋转时保留原比例。"""
    image = master(key)
    box = core_box(image)
    extent = max(box[2]-box[0],box[3]-box[1])
    factor = span*4/extent
    dimensions = tuple(max(1,round(v*factor)) for v in image.size)
    scaled = image.resize(dimensions,Image.Resampling.LANCZOS)
    bx,by = (box[0]+box[2])/2,(box[1]+box[3])/2
    result = Image.new('RGBA',(512,512))
    result.alpha_composite(scaled,(round(center[0]*4-bx*factor),round(center[1]*4-by*factor)))
    if angle:
        result = result.rotate(angle,Image.Resampling.BICUBIC,center=(center[0]*4,center[1]*4))
    return result


@lru_cache(maxsize=2)
def pointer_layer(upward=False):
    """共用对称母版，旋转时保持已确认的缩放比例。"""
    upright = master('arrow')
    baseline = core_box(upright.rotate(SCALE_REFERENCE_ANGLE,Image.Resampling.BICUBIC))
    factor = POINTER_SPAN*4/max(baseline[2]-baseline[0],baseline[3]-baseline[1])
    image = upright if upward else upright.rotate(POINTER_ANGLE,Image.Resampling.BICUBIC)
    box = core_box(image)
    scaled = image.resize(tuple(round(v*factor) for v in image.size),Image.Resampling.LANCZOS)
    result = Image.new('RGBA',(512,512))
    result.alpha_composite(scaled,(round(256-(box[0]+box[2])*factor/2),
                                   round(256-(box[1]+box[3])*factor/2)))
    if upward:
        alpha = result.getchannel('A')
        result.putalpha(Image.blend(alpha,ImageOps.mirror(alpha),.5))
    return result


def pointer(upward=False):
    return pointer_layer(upward).copy()


def raw_role(key,phase=0):
    if key in ('arrow','help','working'):
        result = pointer()
        if key=='help':
            result.alpha_composite(layer('question',21,(94,88)))
        elif key=='working':
            result.alpha_composite(layer('busy',20,(95,88),-phase*360))
        return result
    if key in ('alternate','link'):
        return pointer(True)
    if key=='busy':
        return layer('busy',SPANS[key],angle=-phase*360).copy()
    angles = {'horizontal':0,'vertical':-90,'diagonal_nwse':-45,'diagonal_nesw':45}
    if key in angles:
        return layer('horizontal',SPANS['horizontal'],angle=angles[key]).copy()
    return layer(key,SPANS[key]).copy()


def render_pearl(key,size,phase=0):
    image = raw_role(key,phase)
    alpha = image.getchannel('A')
    # 细暗边增强白色背景辨识度。
    edge = alpha.filter(ImageFilter.MaxFilter(7)).point(lambda v:round(v*.55))
    outline = Image.new('RGBA',image.size,(29,34,48,0))
    outline.putalpha(edge)
    outline.alpha_composite(image)
    result = outline.resize((size,size),Image.Resampling.LANCZOS)
    if key in ('alternate','link'):
        alpha = result.getchannel('A')
        result.putalpha(Image.blend(alpha,ImageOps.mirror(alpha),.5))
    return result


def tip_hotspot(key):
    image = render_pearl(key,128)
    alpha = image.getchannel('A')
    points = [(x,y) for y in range(128) for x in range(128) if alpha.getpixel((x,y))>=220]
    if key in ('arrow','help','working'):
        target = min(points,key=lambda p:p[0]+p[1])
        shift = (1,1)
    elif key in ('alternate','link'):
        minimum = min(y for x,y in points)
        tip = [x for x,y in points if y==minimum]
        target = (round(sum(tip)/len(tip)),minimum)
        shift = (0,1)
    elif key=='handwriting':
        target = min(points,key=lambda p:p[0]-p[1])
        shift = (1,-1)
    elif key=='location':
        maximum = max(y for x,y in points)
        tip = [x for x,y in points if y==maximum]
        target = (round(sum(tip)/len(tip)),maximum)
        shift = (0,-1)
    else:
        return (64,64)
    preferred = (target[0]+shift[0],target[1]+shift[1])
    samples = {size:render_pearl(key,size).getchannel('A') for size in (32,48,64,96,128)}
    choices = [(preferred[0]+dx,preferred[1]+dy) for dx in range(-4,5) for dy in range(-4,5)]
    choices.sort(key=lambda p:math.dist(p,preferred))
    for point in choices:
        if all(alpha.getpixel(tuple(round(v*size/128) for v in point))>=128 for size,alpha in samples.items()):
            return point
    raise ValueError(f'无法为笔尖或尖端找到可靠热点：{key}')


@lru_cache(maxsize=1)
def hotspots():
    result = {key:tip_hotspot(key) for key in ('arrow','link','handwriting','location')}
    result['help'] = result['working'] = result['arrow']
    result['alternate'] = result['link']
    return result
