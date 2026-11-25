# Sizes, RGB, OCR keyword per screenshot headline, video specs, ASO limits.
import subprocess,json,sys,unicodedata
from pathlib import Path
from PIL import Image
from storecopy import KEY
from aso import ASO,NAME
R=Path(__file__).parent;OCR=sys.argv[1];bad=0
def fail(*a):
    global bad;bad+=1;print('FAIL',*a)
norm=lambda s:''.join(c for c in unicodedata.normalize('NFD',s.lower()) if not unicodedata.combining(c)).replace(' ','').replace('\n','').replace('-','')
LANG={'de-DE':'de-DE','fr-FR':'fr-FR','es-ES':'es-ES','es-MX':'es-ES','it':'it-IT','pt-BR':'pt-BR','nl-NL':'nl-NL','ja':'ja-JP','ko':'ko-KR','zh-Hans':'zh-Hans'}
SZ={'iphone-6.9':(1320,2868,9),'iphone-6.3':(1206,2622,9),'ipad-13':(2064,2752,7),'duo-outer':(1398,2034,9)}
hit=tot=0
for l in KEY:
    for fam,(w,h,n) in SZ.items():
        fs=sorted((R/'out'/l/fam).glob('*.png'))
        if len(fs)!=n: fail(l,fam,'count',len(fs))
        for f in fs:
            im=Image.open(f)
            if im.size!=(w,h) or im.mode!='RGB': fail(f,im.size,im.mode)
        o=subprocess.run([OCR,'--languages',LANG.get(l,'en-US'),'--crop','0,0,1,0.27',*map(str,fs)],capture_output=True,text=True).stdout
        for line in o.splitlines():
            d=json.loads(line);tot+=1
            if any(norm(k) in norm(d['text']) for k in KEY[l]): hit+=1
            else: print('no keyword',l,fam,Path(d['file']).name,repr(d['text'][:60]))
    if '--video' in sys.argv:
        for k,(w,h,lo,hi) in {'app-preview/iphone-6.9':(886,1920,15,30),'header/header':(3840,1646,5,30),'search/search':(3840,2560,5,30)}.items():
            f=R/'out'/l/(k+'.mp4')
            j=json.loads(subprocess.run(['ffprobe','-v','error','-of','json','-show_streams','-show_format',str(f)],capture_output=True,text=True).stdout or '{}')
            if not j: fail(f,'missing');continue
            v=[s for s in j['streams'] if s['codec_type']=='video'][0];d=float(j['format']['duration'])
            if (v['width'],v['height'])!=(w,h) or v['r_frame_rate']!='30/1' or not lo<=d<=hi: fail(f,v['width'],v['height'],v['r_frame_rate'],d)
    a=ASO[l]
    if len(a['sub'])>30 or len(a['kw'])>100 or len(a['promo'])>170: fail(l,'ASO length',len(a['sub']),len(a['kw']),len(a['promo']))
    used=set(norm(x) for x in (NAME+' '+a['sub']).replace(':',' ').replace(',',' ').replace('&',' ').split())
    dup=[k for k in a['kw'].split(',') if norm(k) in used]
    if dup: fail(l,'repeats',dup)
print(f'keyword read in {hit}/{tot} screenshots;',bad,'failures')
sys.exit(bad>0)
