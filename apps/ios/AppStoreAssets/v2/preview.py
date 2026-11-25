import subprocess,io
from pathlib import Path
from PIL import Image
from playwright.sync_api import sync_playwright
R=Path(__file__).parent;B=R/'build';B.mkdir(exist_ok=True)
O=-0.9
SC=[ # name, headline, colours, [(footage start,end)]
('a',['Screen','Recorder'],'#ff5a36,#ff2d55,#8b1fa8',[(13.75,18.35)]),
('b',['Zoom in on','every tap'],'#ffb21e,#ff6a2b,#e0245e',[(18.35,22.1)]),
('c',['Add video','backgrounds'],'#ff5fa8,#d6249f,#4a1a9e',[(23.7,27.8)]),
('d',['Auto captions','& subtitles'],'#12c27a,#048a6b,#043b52',[(28.4,31.5)]),
('e',['Record iPhone','screen to Mac'],'#28a8ff,#1264f0,#1a1a8c',[(3.4,8.3)]),
('f',['Export screen','recordings'],'#7b5cff,#4b24e0,#1b0b73',[(31.95,33.5),(100.75,102.2)]),
('g',['Share with','a link'],'#39306e,#ff3b5c,#1b1640',[(110.1,113.3)]),
]
with sync_playwright() as p:
    b=p.chromium.launch(channel='chrome');pg=b.new_page(viewport=dict(width=886,height=1920))
    for n,h,c,_ in SC:
        pg.set_content(f'<body style="margin:0;background:transparent"><div style="width:886px;height:1920px;background:linear-gradient(160deg,{c});opacity:.72"></div></body>');pg.screenshot(path=str(B/f'{n}-tint.png'),omit_background=True)
        pg.set_content(f'<body style="margin:0;width:886px;height:1920px;display:flex;align-items:center;justify-content:center;text-align:center;background:transparent;font:800 128px/.98 system-ui,sans-serif;letter-spacing:-.045em;color:#fff;text-shadow:0 6px 40px #0006"><div>{"<br>".join(h)}</div></body>');pg.screenshot(path=str(B/f'{n}-text.png'),omit_background=True)
    b.close()
total=0;files=[]
for n,h,c,clips in SC:
    dur=sum(e-s for s,e in clips);total+=dur
    fc='';inp=[]
    for i,(s,e) in enumerate(clips):
        inp+=['-ss',str(s),'-t',str(e-s),'-i',str(R/'raw/tour.mov')]
        fc+=f'[{i}:v]fps=30,scale=886:-2,crop=886:1920,setsar=1,setpts=PTS-STARTPTS[c{i}];'
    k=len(clips);inp+=['-loop','1','-t',str(dur),'-i',str(B/f'{n}-tint.png'),'-loop','1','-t',str(dur),'-i',str(B/f'{n}-text.png')]
    fc+=''.join(f'[c{i}]' for i in range(k))+f'concat=n={k}:v=1:a=0,tpad=stop_mode=clone:stop_duration=1,trim=0:{dur},split[s][b0];'
    fc+=f'[b0]gblur=sigma=26[b1];[{k}:v]format=rgba[t];[b1][t]overlay=shortest=1,format=rgba,fade=out:st=0.95:d=0.35:alpha=1[b];'
    fc+=f"[{k+1}:v]format=rgba,fade=in:st=0:d=0.18:alpha=1,fade=out:st=0.9:d=0.25:alpha=1[x];[s][b]overlay=shortest=1[v0];[v0][x]overlay=x=0:y='26*pow(1-min(t/0.35,1),3)':shortest=1,format=yuv420p[v]"
    f=B/f'{n}.mp4';files.append(f)
    subprocess.run(['ffmpeg','-v','error','-y',*inp,'-filter_complex',fc,'-map','[v]','-r','30','-t',str(dur),'-c:v','libx264','-crf','12','-preset','medium',str(f)],check=True)
(B/'l.txt').write_text(''.join(f"file '{f}'\n" for f in files))
out=R/'out/en-US/app-preview';out.mkdir(parents=True,exist_ok=True)
subprocess.run(['ffmpeg','-v','error','-y','-f','concat','-safe','0','-i',str(B/'l.txt'),'-i',str(R.parent/'out/en-US/app-preview/iphone-6.9.mp4'),'-map','0:v','-map','1:a','-t',f'{total:.3f}','-af',f'afade=t=out:st={total-1.2}:d=1.2','-c:v','libx264','-profile:v','high','-level','4.0','-b:v','11M','-minrate','11M','-maxrate','11M','-bufsize','11M','-x264-params','nal-hrd=cbr','-pix_fmt','yuv420p','-r','30','-c:a','aac','-b:a','256k','-ar','48000','-ac','2','-movflags','+faststart',str(out/'iphone-6.9.mp4')],check=True)
print(total)
