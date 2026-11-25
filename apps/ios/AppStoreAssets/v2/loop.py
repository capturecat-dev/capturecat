# header / search seamless loops: every frame is a pure function of t (period 8 s)
import subprocess,sys,io
from pathlib import Path
from PIL import Image
from playwright.sync_api import sync_playwright
R=Path(__file__).parent;loc=sys.argv[2];from_=1
from storecopy import C,R as RT,APP
F=R/'build/ridge'/loc;F.mkdir(parents=True,exist_ok=True);T=8;FPS=30
if not list(F.glob('*.jpg')): subprocess.run(['ffmpeg','-v','error','-y','-i',str(R/'raw'/loc/'ridge.mov'),'-vf','fps=30,scale=804:-1','-q:v','3',str(F/'%03d.jpg')],check=True)
kind=sys.argv[1];test=len(sys.argv)>3
W,H=(3840,1646) if kind=='header' else (3840,2560)
html=('''<style>*{margin:0;box-sizing:border-box}body{width:%dpx;height:%dpx;overflow:hidden;position:relative;font-family:system-ui;color:#fff;background:linear-gradient(120deg,#ff5a36,#ff2d55 42%%,#8b1fa8 75%%,#3a12a0)}
.b{position:absolute;border-radius:50%%;filter:blur(170px)}.p{position:absolute;background:linear-gradient(120deg,#55555c,#111 14%%,#0a0a0c 50%%,#141417 86%%,#55555c);box-shadow:0 60px 140px #0009,inset 0 0 0 4px #ffffff22}.p .s{position:absolute;overflow:hidden;background:#000}.p img{position:absolute;left:0;top:0;width:100%%}
.i{position:absolute;background:#000;border-radius:99px}.r{position:absolute;border-radius:50%%;border:7px solid #fff}h1{font-weight:800;letter-spacing:-.045em;line-height:.95;white-space:nowrap;text-shadow:0 10px 60px #0004}'''+('h1{font-weight:600!important;letter-spacing:0!important}' if sys.argv[2]=='ja' else '')+'''h2{font-weight:600;letter-spacing:-.02em;white-space:nowrap;margin-top:34px}
.cap{position:absolute;background:#000b;border-radius:22px;font-weight:700;white-space:nowrap;text-align:center;transform:translateX(-50%%)}.card{position:absolute;overflow:hidden;box-shadow:0 60px 140px #0008}
</style><body></body>''')%(W,H)
js='''(a)=>{const{t,W,H,kind,frames,dir}=a,T=8,P=Math.PI*2,w=t/T,S=x=>Math.sin(P*x),ease=x=>{x=Math.max(0,Math.min(1,x));return x*x*(3-2*x)};
const hdr=kind=='header';let h='';
h+=`<div class=b style="left:${-300+260*S(w)}px;top:${-500+120*S(w+.25)}px;width:1700px;height:1700px;background:#ffb03a99"></div><div class=b style="left:${W-1500+220*S(w+.5)}px;top:${H-1300+140*S(w)}px;width:1800px;height:1800px;background:#3d5cff88"></div>`;
const src=ft=>{const n=Math.max(1,Math.min(frames,Math.round(ft*30)+1));return dir+'/'+String(n).padStart(3,'0')+'.jpg'};
const ft=2.2+t; const fin=T-.5, mix=t>fin?ease((t-fin)/.5):0;
const scr=(sw,z,ox,oy)=>`<img src="${src(ft)}" style="transform-origin:${ox}% ${oy}%;transform:scale(${z})"><img src="${src(2.2)}" style="opacity:${mix}">`;
const phone=(x,y,w,z,ox,oy,rot)=>{const b=w*.03,sw=w-2*b,sh=sw*874/402;return `<div class=p style="left:${x}px;top:${y}px;width:${w}px;height:${sh+2*b}px;border-radius:${w*.152}px;transform:rotate(${rot}deg)"><div class=s style="left:${b}px;top:${b}px;width:${sw}px;height:${sh}px;border-radius:${w*.152-b}px">${scr(sw,z,ox,oy)}</div><div class=i style="left:${w*.36}px;top:${b+sw*.03}px;width:${w*.28}px;height:${sw*.082}px"></div></div>`};
const zoom=1+.75*(ease((t-.6)/.7)-ease((t-2.9)/.7))+.8*(ease((t-5.2)/.7)-ease((t-7.2)/.6)), oy=t<4?38:88;
const ring=(cx,cy,R0)=>{let o='';for(let i=0;i<4;i++){const k=((w*2+i/4)%%1),r=R0*(.55+.9*k);o+=`<div class=r style="left:${cx-r}px;top:${cy-r}px;width:${2*r}px;height:${2*r}px;opacity:${.5*(1-k)*Math.min(1,k*6)}"></div>`}return o};
const caps=a.caps;const ci=t<.9||t>7.6?0:t<3.6?1:t<5.8?2:3;
if(hdr){
 h+=ring(560,900,760);h+=phone(250,150+26*S(w),620,1,50,50,-5);
 h+=`<div class=card style="left:2950px;top:${170+26*S(w+.5)}px;width:720px;height:1300px;border-radius:80px;transform:rotate(4deg);background:linear-gradient(160deg,#ffb21e,#ff5a3c 45%%,#6a24f0)"><div style="position:absolute;inset:0;transform-origin:50%% ${oy}%%;transform:scale(${zoom})">${phone(120,120,480,1,50,50,0)}</div><div class=cap style="left:50%%;bottom:90px;font-size:38px;padding:20px 30px">${caps[ci]}</div></div>`;
 h+=`<div style="position:absolute;left:1097px;width:1646px;top:493px;height:661px;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center"><h1 style="font-size:${a.fs*228}px">${a.h1}</h1><h2 style="font-size:${a.rs*80}px">${a.rec}</h2></div>`;
}else{
 h+=ring(2560,1500,900);h+=phone(2130,420+30*S(w),900,zoom>1?1:1,50,oy,3);
 h+=`<div class=cap style="left:2580px;top:${1600+30*S(w)}px;font-size:62px;padding:28px 44px;transform:translateX(-50%%) rotate(3deg)">${caps[ci]}</div>`;
 h+=`<div style="position:absolute;left:836px;width:1240px;top:765px;height:1030px;display:flex;flex-direction:column;justify-content:center"><h1 style="font-size:${a.fs*268}px">${a.h1}</h1><h2 style="font-size:${a.rs*92}px">${a.rec}</h2></div>`;
}
document.body.innerHTML=h;return Promise.all([...document.images].map(i=>i.decode()))}'''.replace('%%','%')
page=R/'build'/f'loop-{kind}.html';page.write_text(html)
n=len(list(F.glob('*.jpg')));out=R/'out'/loc/kind;out.mkdir(parents=True,exist_ok=True)
with sync_playwright() as p:
    b=p.chromium.launch(channel='chrome');pg=b.new_page(viewport=dict(width=W,height=H));pg.goto(page.as_uri())
    def fr(t): pg.evaluate(js,dict(t=t,W=W,H=H,kind=kind,frames=n,h1='<br>'.join(C[loc]['s1'][0]),rec=C[loc]['rec'],caps=[RT[APP[loc][2]][f'cap{i}'] for i in (1,2,3,4)],fs=min(1,8.6/max(sum(1.75 if ord(x)>0x2e80 else 1 for x in y) for y in C[loc]['s1'][0])),rs=min(1,24/sum(1.75 if ord(x)>0x2e80 else 1 for x in C[loc]['rec'])),dir=F.as_uri()))
    if test:
        for i,t in enumerate([0,1.8,4,6]): fr(t);Image.open(io.BytesIO(pg.screenshot())).convert('RGB').resize((W//3,H//3)).save(R/'build'/f'{kind}-{i}.png')
    else:
        fr(4.3);Image.open(io.BytesIO(pg.screenshot())).convert('RGB').save(out/f'{kind}.png')
        ff=subprocess.Popen(['ffmpeg','-v','error','-y','-f','image2pipe','-c:v','mjpeg','-r','30','-i','-','-vf','format=yuv420p','-c:v','libx264','-profile:v','high','-preset','medium','-crf','17','-r','30','-movflags','+faststart',str(out/f'{kind}.mp4')],stdin=subprocess.PIPE)
        for i in range(T*FPS): fr(i/FPS);ff.stdin.write(pg.screenshot(type='jpeg',quality=95))
        ff.stdin.close();ff.wait()
    b.close()
