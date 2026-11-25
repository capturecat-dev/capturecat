import subprocess,io
from pathlib import Path
from PIL import Image
from playwright.sync_api import sync_playwright
R=Path(__file__).parent;B=R/'build';B.mkdir(exist_ok=True)
import sys
from storecopy import C
loc=sys.argv[1];c=C[loc];D=R/'raw'/loc;B=B/loc;B.mkdir(parents=True,exist_ok=True)
t=dict((l.split()[1],float(l.split()[0])-.9) for l in (D/'tour.txt').read_text().splitlines())
TOUR=B/'tour-cfr.mp4'
subprocess.run(['ffmpeg','-v','error','-y','-i',str(D/'tour.mov'),'-vf','fps=30,scale=886:-2,crop=886:1920,setsar=1','-c:v','libx264','-preset','veryfast','-crf','12','-g','15','-an',str(TOUR)],check=True)
dur_=float(subprocess.run(['ffprobe','-v','error','-show_entries','format=duration','-of','csv=p=0',str(TOUR)],capture_output=True,text=True).stdout)
t['share-detail']+=dur_-(t['end']+.9)-.05   # the recorder can lose time during the export
j=lambda k:c[k][0]
SC=[
('a',j('s1'),'#ff5a36,#ff2d55,#8b1fa8',[(t['play']+.3,t['play']+4.5)]),
('b',j('s3'),'#ffb21e,#ff6a2b,#e0245e',[(t['play']+4.9,t['play']+8.5)]),
('h',j('s9'),'#39306e,#5b3cff,#1b1640',[(t['ai']-.6,t['ai']+3.0)]),
('c',j('s5'),'#ff5fa8,#d6249f,#4a1a9e',[(t['background']+.4,t['background']+4.2)]),
('d',j('s4'),'#12c27a,#048a6b,#043b52',[(t['subtitles']+.5,t['subtitles']+3.1)]),
('e',j('s6'),'#28a8ff,#1264f0,#1a1a8c',[(t['capture']+1.6,t['capture']+6.5)]),
('f',c['exp'],'#7b5cff,#4b24e0,#1b0b73',[(t['export']+.2,t['export']+1.6),(t['exported']+1.15,t['exported']+2.4)]),
('g',j('s7'),'#39306e,#ff3b5c,#1b1640',[(t['share-detail']+1.7,t['share-detail']+4.7)]),
]
with sync_playwright() as p:
    b=p.chromium.launch(channel='chrome');pg=b.new_page(viewport=dict(width=886,height=1920))
    for n,h,c,_ in SC:
        pg.set_content(f'<body style="margin:0;background:transparent"><div style="width:886px;height:1920px;background:linear-gradient(160deg,{c});opacity:.72"></div></body>');pg.screenshot(path=str(B/f'{n}-tint.png'),omit_background=True)
        pg.set_content(f'<body style="margin:0;width:886px;height:1920px;display:flex;align-items:center;justify-content:center;text-align:center;background:transparent;font:800 {min(128,int(1560/max(sum(2 if ord(ch)>0x2e80 else 1.05 for ch in x) for x in h)))}px/1.0 system-ui,sans-serif;letter-spacing:-.045em;color:#fff;text-shadow:0 6px 40px #0006"><div>{"<br>".join(h)}</div></body>');pg.screenshot(path=str(B/f'{n}-text.png'),omit_background=True)
    b.close()
total=0;files=[]
for n,h,c,clips in SC:
    dur=sum(e-s for s,e in clips);total+=dur
    fc='';inp=[]
    for i,(s,e) in enumerate(clips):
        inp+=['-ss',str(s),'-t',str(e-s),'-i',str(TOUR)]
        fc+=f'[{i}:v]fps=30,scale=886:-2,crop=886:1920,setsar=1,setpts=PTS-STARTPTS[c{i}];'
    k=len(clips);inp+=['-loop','1','-t',str(dur),'-i',str(B/f'{n}-tint.png'),'-loop','1','-t',str(dur),'-i',str(B/f'{n}-text.png')]
    fc+=''.join(f'[c{i}]' for i in range(k))+f'concat=n={k}:v=1:a=0,tpad=stop_mode=clone:stop_duration=1,trim=0:{dur},split[s][b0];'
    fc+=f'[b0]gblur=sigma=26[b1];[{k}:v]format=rgba[t];[b1][t]overlay=shortest=1,format=rgba,fade=out:st=0.95:d=0.35:alpha=1[b];'
    fc+=f"[{k+1}:v]format=rgba,fade=in:st=0:d=0.18:alpha=1,fade=out:st=0.9:d=0.25:alpha=1[x];[s][b]overlay=shortest=1[v0];[v0][x]overlay=x=0:y='26*pow(1-min(t/0.35,1),3)':shortest=1,format=yuv420p[v]"
    f=B/f'{n}.mp4';files.append(f)
    subprocess.run(['ffmpeg','-v','error','-y',*inp,'-filter_complex',fc,'-map','[v]','-r','30','-t',str(dur),'-c:v','libx264','-crf','12','-preset','medium',str(f)],check=True)
(B/'l.txt').write_text(''.join(f"file '{f}'\n" for f in files))
out=R/'out'/loc/'app-preview';out.mkdir(parents=True,exist_ok=True)
subprocess.run(['ffmpeg','-v','error','-y','-f','concat','-safe','0','-i',str(B/'l.txt'),'-i',str(R.parent/'out/en-US/app-preview/iphone-6.9.mp4'),'-map','0:v','-map','1:a','-t',f'{total:.3f}','-af',f'afade=t=out:st=26.2:d=1.3,apad','-c:v','libx264','-profile:v','high','-level','4.0','-b:v','11M','-minrate','11M','-maxrate','11M','-bufsize','11M','-x264-params','nal-hrd=cbr','-pix_fmt','yuv420p','-r','30','-c:a','aac','-b:a','256k','-ar','48000','-ac','2','-movflags','+faststart',str(out/'iphone-6.9.mp4')],check=True)
print(loc,round(total,2))
