import sys,io
from pathlib import Path
from PIL import Image
from playwright.sync_api import sync_playwright
R=Path(__file__).parent
from storecopy import C,KEY
def src(f,n): return (R/'raw'/f/f'{n}.png').as_uri()
BG={
'red':("linear-gradient(160deg,#ff5a36,#ff2d55 45%,#a3147f)",[(-20,-8,70,'#ffb03a99'),(55,45,80,'#6a11cb99')]),
'violet':("linear-gradient(165deg,#7b5cff,#4b24e0 55%,#1b0b73)",[(50,-10,80,'#ff5fd299'),(-25,50,80,'#1fb6ff66')]),
'sun':("linear-gradient(160deg,#ffb21e,#ff6a2b 50%,#e0245e)",[(-20,50,90,'#8b1fd488'),(55,-6,60,'#ffe86a99')]),
'green':("linear-gradient(160deg,#12c27a,#048a6b 50%,#043b52)",[(50,-8,80,'#c8f55a88'),(-25,55,80,'#1479ff66')]),
'blue':("linear-gradient(160deg,#28a8ff,#1264f0 50%,#1a1a8c)",[(-20,-8,80,'#5ff0ff88'),(50,50,80,'#8b3dff88')]),
'pink':("linear-gradient(160deg,#ff5fa8,#d6249f 50%,#4a1a9e)",[(50,-8,80,'#ffb86a99'),(-25,55,80,'#3d5cff77')]),
'ink':("linear-gradient(160deg,#39306e,#1b1640 50%,#07060f)",[(50,0,80,'#ff3b5c77'),(-25,50,90,'#4d7dff66')]),
}
# crop boxes in the raw 1320x2868 iPhone shots
SHOTS=[('01-screen-recorder','red','s1','RIDGE','rec'),('02-edit','violet','s2','editor','timeline'),('03-ai','ink','s9','ai','ai'),('04-zoom','sun','s3','export','stage'),('05-captions','green','s4','captions','captions'),('06-backgrounds','pink','s5','background','fan'),('07-to-mac','blue','s6','capture','hero'),('08-share','ink','s7','share','share'),('09-library','violet','s8','library','')]
IPS=[('01-screen-recorder','red','s1','editor','timeline'),('02-ai','ink','s9','ai','ai'),('03-captions','green','s4','captions','stage'),('04-backgrounds','pink','s5','background','stage'),('05-to-mac','blue','s6','capture','hero'),('06-share','ink','s7','share',''),('07-library','violet','s8','library','')]
import json
def cards(loc,fam,n,cls='CCCard'):
    f=R/'raw'/loc/fam/f'{n}.json'
    return sorted([c['f'] for c in json.loads(f.read_text()) if c['c']==cls],key=lambda f:(f[1],f[0]))
def spec(loc,fam,it):
    c=C[loc];k,bg,key,img,kind=it;pad=fam=='ipad-13';rf='ipad' if pad else 'iphone'
    h1,h2=c[key]
    if pad and key=='s1': h2=c['ip1']
    if pad and key=='s6': h1=c['ip6']
    cjk=loc in('ja','ko','zh-Hans')
    if pad: h1=[(''if cjk and loc!='ko' else ' ').join(h1).replace('- ','')]
    W,H=(2064,2752) if pad else (1320,2868) if fam=='iphone-6.9' else (1206,2622)
    g=W/1320 if not pad else 1
    P=lambda n:(R/'raw'/loc/rf/f'{n}.png').as_uri()
    fs=(230 if key=='s1' else 200) if pad else {'s1':262,'s2':212,'s3':206,'s8':206}.get(key,190)*g
    top=140 if pad else 150*g;lines=len(h1)
    if pad: dy=top+fs+fs*.36+190
    else: dy=top+fs*.98*2+fs*.36+150*g
    if not pad and lines==1: top+=fs*.45
    dw=1760 if pad else 1090*g
    iw=2064 if pad else 1320;q=2 if pad else 3
    px=lambda f,m=0:(f[0]*q-m,f[1]*q-m,f[2]*q+2*m,f[3]*q+2*m)
    L=[];add=lambda n,crop,w,**kw:L.append(dict(dict(src=P(n),iw=iw,crop=crop,w=w*g,x=(W-w*g)/2,y=0,r=40,rr=(70 if pad else 80)*g,home=1,bg='#1e1d21'),**kw))
    if kind=='rec':
        add('capture',px(cards(loc,rf,'capture')[1]),1210,home=0,y=1950*g,rr=1210*g*.044)
    elif kind=='timeline':
        if pad: add('editor',(0,1042,1376,480),1500,dx=-150)
        else: add('editor',(0,1440,1320,730),1250)
    elif kind=='ai':
        f=cards(loc,rf,'ai','CCToast')[0];cr=px(f)
        im0=Image.open(R/'raw'/loc/rf/'ai.png').convert('RGB');x,y,w,h=map(int,px(f,40));col=im0.getpixel((8 if not pad else 700,y-30))
        im0.paste(col,(0 if not pad else x,y,im0.width if not pad else x+w,min(im0.height,y+h+120)));im0.save(R/'raw'/loc/rf/'ai-clean.png')
        img='ai-clean'
        add('ai',cr,(1300 if pad else 1250),home=0,y=(2160 if pad else 2440*g),rr=(44 if pad else 60)*g)
        L.append(dict(prompt=c['prompt'],w=(1300 if pad else 1140)*g,x=(W-(1300 if pad else 1140)*g)/2,y=(1800 if pad else 2070*g),fs=(62 if pad else 64)*g))
    elif kind=='stage':
        if pad: add(img,(301,161,780,776),1500,home=0,x=282,y=640)
        else: add(img,(178,330,964,836),1220)
    elif kind=='captions':
        t=cards(loc,rf,'captions','InspectorPresetCard')[:5]
        x0,y0=t[0][0]*3,t[0][1]*3;x1=(t[4][0]+t[4][2])*3
        yh=min(2868-y0,50*3)
        add('captions',(x0,y0,x1-x0,yh),1220,pad=52*g,bg='linear-gradient(#36363b,#323236)',dy=-60*g)
    elif kind=='fan':
        for n,w,x,y,rot in (('bg-blue',760,-110,1250,-9),('bg-green',760,670,1250,9),('bg-orange',900,210,1480,0)):
            add(n,(180,332,960,838),w,home=0,x=x*g,y=y*g,rr=70*g,rot=rot)
    elif kind=='hero': add('capture',px(cards(loc,rf,'capture')[0]),1640 if pad else 1200,dy=40 if pad else 0)
    elif kind=='share': add('share',px(cards(loc,rf,'share')[0]),1210)
    im=(R/'raw'/loc/'ridge-7.png').as_uri() if img=='RIDGE' else P(img)
    return dict(W=W,H=H,bg=BG[bg][0],blobs=BG[bg][1],h1=h1,h2=h2,fs=fs,top=top,cjk=cjk,ja=loc=='ja',dev=dict(w=dw,y=dy,bez=.022 if pad else .03,rad=.05 if pad else .152,ar=2752/2064 if pad else 2868/1320,src=im,isl=not pad,ring=kind=='rec'),lifts=L,dim=bool(L))
def prep(loc):
    import subprocess
    d=R/'raw'/loc
    subprocess.run(['ffmpeg','-v','error','-y','-ss','7','-i',str(d/'ridge.mov'),'-frames:v','1',str(d/'ridge-7.png')],check=True)
    t=dict((l.split()[1],float(l.split()[0])) for l in (d/'tour.txt').read_text().splitlines())
    for n,o in (('blue',.45),('green',1.5),('orange',2.6)):
        subprocess.run(['ffmpeg','-v','error','-y','-ss',str(t['mesh']-.9+o),'-i',str(d/'tour.mov'),'-frames:v','1',str(d/'iphone'/f'bg-{n}.png')],check=True)
def main():
    locs=sys.argv[1].split(',');fams=sys.argv[2].split(',') if len(sys.argv)>2 else ['iphone-6.9','iphone-6.3','ipad-13']
    with sync_playwright() as p:
        b=p.chromium.launch(channel='chrome')
        for loc in locs:
            if any(f!='ipad-13' for f in fams): prep(loc)
            for fam in fams:
                out=R/'out'/loc/fam;out.mkdir(parents=True,exist_ok=True)
                for o in out.glob('*.png'): o.unlink()
                for it in (IPS if fam=='ipad-13' else SHOTS):
                    s=spec(loc,fam,it);pg=b.new_page(viewport=dict(width=s['W'],height=s['H']));pg.goto((R/'canvas.html').as_uri());pg.evaluate('s=>render(s)',s)
                    if pg.evaluate("FIT.h2<.5"): print('SMALL SUB',loc,fam,it[0])
                    Image.open(io.BytesIO(pg.screenshot())).convert('RGB').save(out/f'{it[0]}.png');pg.close()
            print('rendered',loc,flush=True)
        b.close()
main()
