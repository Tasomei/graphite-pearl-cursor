from __future__ import annotations

import hashlib
import io
import json
import struct
import zipfile
from dataclasses import replace
from datetime import datetime
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

from cursor_format import native_check, png_bytes, ANIMATION_FRAMES, ANIMATION_JIFFIES, CURSOR_SIZES, ROLES, build_ani_bytes, build_cur_bytes, find_preview_font
from pearl_artwork import ASSETS, POINTER_ANGLE, POINTER_MASTER, core_box, hotspots, layer, render_pearl


ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT/'package'/'GraphitePearl'
CURSORS = PACKAGE/'cursors'
ANIMATED_SIZES = (32,48,64)
STAMP = datetime.now().strftime('%Y%m%d_%H%M%S')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path,data):
    """覆盖前备份，并检测外部修改。"""
    path.parent.mkdir(parents=True,exist_ok=True)
    if path.exists():
        old = path.read_bytes()
        if old==data:
            return
        backup = path.parent/'_备份'/f'{path.stem}_{STAMP}{path.suffix}'
        backup.parent.mkdir(parents=True,exist_ok=True)
        if backup.exists():
            raise FileExistsError(backup.name)
        backup.write_bytes(old)
        assert backup.read_bytes()==old and path.read_bytes()==old
    path.write_bytes(data)


def decode(data,sizes,hotspot):
    assert struct.unpack_from('<HHH',data) == (0,2,len(sizes))
    decoded,actual_hotspots = {},{}
    end = 6+16*len(sizes)
    for index,size in enumerate(sizes):
        w,h,_,_,hx,hy,length,offset = struct.unpack_from('<BBBBHHII',data,6+index*16)
        assert (w,h)==(size,size) and offset==end
        assert (hx,hy)==tuple(round(v*size/128) for v in hotspot)
        assert 0<=hx<size and 0<=hy<size
        assert struct.unpack_from('<IiiHH',data,offset)==(40,size,size*2,1,32)
        stride = ((size+31)//32)*4
        assert length==40+4*size*size+stride*size
        image = Image.frombytes('RGBA',(size,size),data[offset+40:offset+40+4*size*size],'raw','BGRA',0,-1)
        mask = data[offset+40+4*size*size:offset+length]
        alpha = image.getchannel('A')
        for y in range(size):
            for x in range(size):
                bit = bool(mask[(size-1-y)*stride+x//8] & (0x80>>(x%8)))
                assert bit==(alpha.getpixel((x,y))<16)
        for edge in ((0,0,size,1),(0,size-1,size,size),(0,0,1,size),(size-1,0,size,size)):
            assert alpha.crop(edge).getextrema()[1]<=2
        decoded[size],actual_hotspots[size] = image,(hx,hy)
        end = offset+length
    assert end==len(data)
    return decoded,actual_hotspots


def ani_frames(data):
    assert data[:4]==b'RIFF' and data[8:12]==b'ACON'
    assert struct.unpack_from('<I',data,4)[0]+8==len(data)
    position,frames = 12,[]
    while position<len(data):
        tag,size = struct.unpack_from('<4sI',data,position)
        chunk = data[position+8:position+8+size]
        assert len(chunk)==size
        if tag==b'anih':
            header = struct.unpack('<9I',chunk)
            assert header[1:3]==(ANIMATION_FRAMES,ANIMATION_FRAMES)
            assert header[7]==ANIMATION_JIFFIES
        if tag==b'LIST':
            assert chunk[:4]==b'fram'
            inner = 4
            while inner<len(chunk):
                key,length = struct.unpack_from('<4sI',chunk,inner)
                assert key==b'icon'
                frames.append(chunk[inner+8:inner+8+length])
                inner+=8+length+length%2
            assert inner==len(chunk)
        position+=8+size+size%2
    assert position==len(data) and len(frames)==ANIMATION_FRAMES
    return frames


def make_preview(roles,previews):
    sheet = Image.new('RGB',(1080,1140),(239,237,234))
    draw = ImageDraw.Draw(sheet)
    for index,role in enumerate(roles):
        row,column = divmod(index,4)
        x,y = 20+260*column,20+220*row
        draw.rounded_rectangle((x,y,x+248,y+206),radius=16,fill=(32,35,43))
        draw.text((x+14,y+12),role.label_zh,font=find_preview_font(19,True),fill=(242,241,247))
        cursor = previews[role.key].resize((240,240),Image.Resampling.LANCZOS)
        sheet.paste(cursor,(x+4,y-8),cursor)
    save(PACKAGE/'preview.png',png_bytes(sheet))
    actual = Image.new('RGB',(810,1030),(244,242,239))
    draw = ImageDraw.Draw(actual)
    draw.text((24,18),'64 像素画布 · 实际大小',font=find_preview_font(25,True),fill=(34,37,46))
    for index,role in enumerate(roles):
        row,column = divmod(index,3)
        x,y = 15+265*column,72+156*row
        draw.text((x+7,y),role.label_zh,font=find_preview_font(17),fill=(42,45,54))
        draw.rounded_rectangle((x+3,y+30,x+127,y+132),radius=12,fill=(29,33,43))
        draw.rounded_rectangle((x+133,y+30,x+257,y+132),radius=12,fill=(255,255,255))
        cursor = render_pearl(role.key,64)
        for shift in (0,130):
            actual.paste(cursor,(x+33+shift,y+49),cursor)
    save(PACKAGE/'preview-actual.png',png_bytes(actual))


def animation_preview():
    frames = []
    for index in range(ANIMATION_FRAMES):
        frame = Image.new('RGB',(600,180),(34,38,49))
        draw = ImageDraw.Draw(frame)
        for column,key in enumerate(('working','busy')):
            draw.text((32+300*column,18),'后台工作' if column==0 else '忙碌',font=find_preview_font(20),fill=(242,241,247))
            cursor = render_pearl(key,128,index/ANIMATION_FRAMES)
            frame.paste(cursor,(86+300*column,43),cursor)
        frames.append(frame)
    output = io.BytesIO()
    frames[0].save(output,format='GIF',save_all=True,append_images=frames[1:],duration=[70,60,70]*4,loop=0)
    save(PACKAGE/'animation-preview.gif',output.getvalue())


def main():
    roles = [replace(role,hotspot=hotspots().get(role.key,(64,64))) for role in ROLES]
    entries,previews = [],{}
    for role in roles:
        sizes = ANIMATED_SIZES if role.animated else CURSOR_SIZES
        frames = []
        for index in range(ANIMATION_FRAMES if role.animated else 1):
            images = {size:render_pearl(role.key,size,index/ANIMATION_FRAMES) for size in sizes}
            frames.append(build_cur_bytes(images,role.hotspot))
        payload = build_ani_bytes(frames) if role.animated else frames[0]
        decoded_frames = ani_frames(payload) if role.animated else [payload]
        signatures = {size:set() for size in sizes}
        for index,frame in enumerate(decoded_frames):
            decoded,actual_hotspots = decode(frame,sizes,role.hotspot)
            for size,image in decoded.items():
                assert image.tobytes()==render_pearl(role.key,size,index/ANIMATION_FRAMES).tobytes()
                signatures[size].add(digest(image.tobytes()))
        if role.animated:
            assert all(len(values)==ANIMATION_FRAMES for values in signatures.values())
        for size in sizes:
            if role.key in ('arrow','help','working','alternate','link','handwriting','location'):
                assert render_pearl(role.key,size).getchannel('A').getpixel(actual_hotspots[size])>=100,(role.key,size,'热点偏离主体')
        path = CURSORS/role.file_name
        save(path,payload)
        native_check(path,actual_hotspots)
        previews[role.key] = render_pearl(role.key,128)
        box = core_box(render_pearl(role.key,64))
        entries.append({'role':role.key,'label_zh':role.label_zh,'file':'cursors/'+role.file_name,
                        'animated':role.animated,'hotspot_logical_128':role.hotspot,
                        'hotspots':actual_hotspots,'sizes':sizes,'sha256':digest(payload),
                        'visible_extent_at_64':max(box[2]-box[0],box[3]-box[1])})
    assert (CURSORS/'alternate.cur').read_bytes()==(CURSORS/'link.cur').read_bytes()
    for size in CURSOR_SIZES:
        a = render_pearl('arrow',size).getchannel('A').point(lambda v:255 if v>=192 else 0)
        for phase in range(ANIMATION_FRAMES):
            for key,span,center,angle in (('busy',20,(95,88),-phase*30),('question',21,(94,88),0)):
                badge = layer(key,span,center,angle).resize((size,size),Image.Resampling.LANCZOS)
                b = badge.getchannel('A').point(lambda v:255 if v>=192 else 0)
                assert ImageChops.multiply(a.filter(ImageFilter.MaxFilter(3)),b).getbbox() is None,(key,size,'角标间距不足')
    assets = {'arrow':POINTER_MASTER}
    assets.update({p.stem:p for p in (ASSETS/'pearl').glob('*.png')})
    manifest = {'name':'Graphite Pearl Cursor','version':(ROOT/'VERSION').read_text(encoding='utf-8').strip(),'size_scale':.9,
                'pointer_angle_from_up_degrees':POINTER_ANGLE,'upright_pointer_symmetric':True,
                'cursor_canvas_sizes':CURSOR_SIZES,'animation_canvas_sizes':ANIMATED_SIZES,
                'animation_frames':ANIMATION_FRAMES,'frame_jiffies':ANIMATION_JIFFIES,
                'source_assets':{key:digest(path.read_bytes()) for key,path in assets.items()},'roles':entries}
    save(PACKAGE/'manifest.json',(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n').encode('utf-8'))
    make_preview(roles,previews)
    animation_preview()
    for name in ('LICENSE','LICENSE-ASSETS.md','THIRD_PARTY_NOTICES.md'):
        save(PACKAGE/name,(ROOT/name).read_bytes())
    save(PACKAGE/'Apply.ps1',(ROOT/'source/apply_pearl_theme.ps1').read_text(encoding='utf-8').encode('utf-8-sig'))
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer,'w',zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(PACKAGE.rglob('*')):
            if path.is_file() and '_备份' not in path.parts:
                archive.write(path,Path('GraphitePearl')/path.relative_to(PACKAGE))
    save(ROOT/'Graphite-Pearl-Cursor-Windows.zip',buffer.getvalue())
    print('PASS: 17 roles; 75 static and 72 animated images; native loading and hotspots')
    print('PASS: alternate and link are byte-identical; moving ring separated from pointer')
    print('Visible extents at 64px:',{r['role']:r['visible_extent_at_64'] for r in entries})
    print('Package:',PACKAGE)


if __name__=='__main__':
    main()
