import subprocess as sp,time,sys,signal,shutil,os
from pathlib import Path
sys.path.insert(0,'/Users/mike/Apps/capturecat/apps/ios/AppStoreAssets/v2')
from storecopy import APP
fam,U=sys.argv[1:3];locs=sys.argv[3:]
V=Path('/Users/mike/Apps/capturecat/apps/ios/AppStoreAssets/v2/raw');A='so.capturecat.ios'
def sim(*a,**k): return sp.run(['xcrun','simctl',*a],capture_output=True,text=True,**k)
for loc in locs:
    lang,reg,_=APP[loc];L=['-AppleLanguages',f'({lang})','-AppleLocale',reg,'-uiStoreLocalizedContent']
    out=V/loc/fam;out.mkdir(parents=True,exist_ok=True)
    sim('terminate',U,A);D=Path(sim('get_app_container',U,A,'data').stdout.strip())
    shutil.rmtree(D/'Library/Caches',ignore_errors=True)
    F=['-uiFixtures','-uiFixtureNoInbox','-uiStoreArt','-uiStoreDump']
    def shot(k,w,*a):
        j=D/'Documents/dump.json'
        if j.exists(): j.unlink()
        sim('launch','--terminate-running-process',U,A,*F,*a,*L);time.sleep(w)
        sim('io',U,'screenshot',str(out/f'{k}.png'))
        if j.exists(): shutil.copy(j,out/f'{k}.json')
    ED=['-uiStoreAspect','1:1']
    shot('warm',26,'-uiStoreEditor','zoom')
    shot('editor',13,*ED,'-uiStoreEditor','zoom','-uiStoreTime','5.0','-uiStoreTimelineZoom','1')
    shot('background',12,*ED,'-uiStoreEditor','background','-uiStorePane','-uiStoreTime','7.2')
    shot('captions',12,*ED,'-uiStoreEditor','captions','-uiStorePane','-uiStoreTime','6.4')
    shot('export',12,*ED,'-uiStoreEditor','captions','-uiStoreTime','9.4')
    shot('ai',12,*ED,'-uiStoreEditor','ai','-uiStoreTime','6.8')
    pad=['-uiSidebarFull'] if fam=='ipad' else []
    shot('library',13,*pad,*(['-uiFixtureScreen','project'] if pad else []))
    shot('capture',10,*pad,'-uiFixtureScreen','capture','-uiFixturePresence','connected')
    shot('share',11,*pad,'-uiFixtureScreen','share')
    if fam=='iphone':
        m=list((D/'Library/Caches/StoreCreative').glob('ridge-v3-*.mov'));shutil.copy(m[0],V/loc/'ridge.mov')
        rec=sp.Popen(['xcrun','simctl','io',U,'recordVideo','--codec','h264','--mask=ignored','--force',str(V/loc/'tour.mov')],stderr=sp.PIPE,text=True)
        for l in rec.stderr:
            if 'Recording started' in l: break
        t0=time.time();p=sp.Popen(['xcrun','simctl','launch','--console-pty','--terminate-running-process',U,A,*F[:3],*ED,'-uiStoreTour',*L],stdout=sp.PIPE,text=True,errors='replace')
        o=open(V/loc/'tour.txt','w')
        for l in p.stdout:
            if 'STORETOUR' in l:
                o.write('%.2f %s\n'%(time.time()-t0,l.split('STORETOUR')[1].strip()));o.flush()
                if ' end' in l or 'FAIL' in l or time.time()-t0>260: break
        time.sleep(1);rec.send_signal(signal.SIGINT);rec.wait();p.kill()
    print(loc,fam,len(list(out.glob('*.png'))),flush=True)
