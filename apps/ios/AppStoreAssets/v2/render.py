import sys,io
from pathlib import Path
from PIL import Image
from playwright.sync_api import sync_playwright
R=Path(__file__).parent
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
IP=[
('01-screen-recorder','red',['Screen','Recorder'],'Record iPhone with audio',dict(img='RIDGE'),[('capture',(50,1778,1220,458),1200,1960,52)],1.2,True),
('02-edit','violet',['Edit Screen','Recordings'],'Cut, zoom and add text on iPhone',dict(img='editor'),[('editor',(0,1440,1320,730),1250,1830,44)],1,False),
('03-zoom','sun',['Zoom Screen','Recordings'],'Show every tap up close',dict(img='export'),[('export',(178,330,964,836),1220,1060,40)],.96,False),
('04-captions','green',['Auto Captions','& Subtitles'],'For every screen recording',dict(img='captions'),[('captions',(304,1054,712,78),1220,1556,30),('captions',(46,2384,1080,152),1220,2180,50)],.9,False),
('05-backgrounds','pink',['Screen Video','Backgrounds'],'Phone frames and gradients',dict(img='background'),'FAN',.92,False),
('06-iphone-to-mac','blue',['Record iPhone','Screen to Mac'],'Over Wi-Fi. No cable.',dict(img='capture'),[('capture',(48,386,1224,1320),1190,1010,70)],.88,False),
('07-share','ink',['Share Screen','Videos by Link'],'With comments and reactions',dict(img='share'),[('share',(48,1446,1224,498),1190,1960,50)],.9,False),
('08-library','violet',['Every Screen','Recording'],'Synced to iPhone, iPad and Mac',dict(img='library'),[],1,False),
]
def spec(fam,it):
    k,bg,h1,h2,d,lifts,fk,ring=it
    if fam=='iphone-6.9': W,H=1320,2868
    else: W,H=1206,2622
    g=W/1320
    fs=(232 if fk==1.2 else 205*fk if fk<1 else 205)*g
    fs={1.2:262,1:212,.92:196,.9:184,.88:186,.96:206}[fk]*g
    top=150*g
    dy=(top+fs*1.96+fs*.36+150*g)
    dw=1090*g
    im=(R/'raw'/'ridge-7.0.png').as_uri() if d['img']=='RIDGE' else src('iphone',d['img'])
    L=[]
    if lifts=='FAN':
        for n,w,x,y,rot in (('bg-blue',760,-110,1250,-9),('bg-green',760,670,1250,9),('bg-orange',900,210,1480,0)):
            L.append(dict(src=src('iphone',n),iw=1320,crop=(180,332,960,838),w=w*g,x=x*g,y=y*g,r=40,rr=70*g,rot=rot,zfix=1))
        lifts=[]
    for n,c,w,y,r in lifts:
        sheet=c[1] in (2384,1826); 
        L.append(dict(src=src('iphone',n),iw=1320,crop=c,w=w*g,x=(W-w*g)/2,y=y*g,r=r,rr=(r if r<40 else 88)*g,home=d['img']!='RIDGE',pad=(52 if sheet else 0)*g,bg='linear-gradient(#36363b,#323236)' if sheet else '#1e1d21',dy=(-40*g if c[1]==2384 else 0)))
    return dict(W=W,H=H,bg=BG[bg][0],blobs=BG[bg][1],h1=h1,h2=h2,fs=fs,top=top,dev=dict(w=dw,y=dy,bez=.03,rad=.152,ar=2868/1320,src=im,isl=True,ring=ring),lifts=L,dim=bool(L))
IPAD=[
('01-screen-recorder','red',['Screen Recorder'],'Record and edit screen videos on iPad','editor'),
('02-captions','green',['Auto Captions & Subtitles'],'For every screen recording','captions'),
('03-backgrounds','pink',['Screen Video Backgrounds'],'Device frames, gradients and zoom','background'),
('04-ipad-to-mac','blue',['Record iPad Screen to Mac'],'Over Wi-Fi. No cable.','capture'),
('05-share','ink',['Share Screen Videos by Link'],'With comments and reactions','share'),
('06-library','violet',['Every Screen Recording'],'Synced to iPad, iPhone and Mac','library'),
]
def ispec(it):
    k,bg,h1,h2,img=it;W,H=2064,2752
    fs=min(250,1800/(len(h1[0])*.505))
    top=140;dy=top+fs+fs*.36+170
    L=[]
    st={'editor':(301,161,780,776),'export':(301,161,780,776),'background':(301,161,780,776)}.get(img)
    if img=='editor': L=[dict(src=src('ipad',img),iw=2064,crop=(0,1042,1376,480),w=1500,x=70,y=1800,r=40,home=1,dx=-150)]
    elif img=='captions': L=[dict(src=src('ipad',img),iw=2064,crop=(301,161,780,776),w=1500,x=282,y=640,r=26)]
    elif st: L=[dict(src=src('ipad',img),iw=2064,crop=st,w=1500,x=282,y=640,r=26)]
    if img=='capture': L=[dict(src=src('ipad',img),iw=2064,crop=(672,206,1218,850),w=1640,x=212,y=700,r=40)]
    return dict(W=W,H=H,bg=BG[bg][0],blobs=BG[bg][1],h1=h1,h2=h2,fs=fs,top=top,dev=dict(w=1760,y=dy,bez=.022,rad=.05,ar=2752/2064,src=src('ipad',img),isl=False),lifts=[dict(l,rr=70) for l in L],dim=bool(L))
def main():
    only=sys.argv[1:] or ['iphone-6.9','iphone-6.3','ipad-13']
    with sync_playwright() as p:
        b=p.chromium.launch(channel='chrome')
        for fam in only:
            out=R/'out'/'en-US'/fam;out.mkdir(parents=True,exist_ok=True)
            for it in (IPAD if fam=='ipad-13' else IP):
                s=ispec(it) if fam=='ipad-13' else spec(fam,it)
                pg=b.new_page(viewport=dict(width=s['W'],height=s['H']));pg.goto((R/'canvas.html').as_uri());pg.evaluate('s=>render(s)',s)
                w=pg.evaluate("(()=>{let r=document.createRange(),m=0;for(const e of document.querySelectorAll('h1,h2')){r.selectNodeContents(e);m=Math.max(m,r.getBoundingClientRect().width)}return m})()")
                if w>s['W']*.93: print('TOO WIDE',fam,it[0],w/s['W'])
                Image.open(io.BytesIO(pg.screenshot())).convert('RGB').save(out/f'{it[0]}.png');pg.close()
        b.close()
main()
