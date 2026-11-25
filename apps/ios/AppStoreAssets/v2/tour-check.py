import subprocess,sys
sys.path.insert(0,'.')
K=[('capture',2.2),('capture',6.2),('play',6.8),('ai',1.2),('background',1.5),('mesh',1.2),('subtitles',1.0),('subtitles',2.9),('export',.5),('export',1.3),('exported',1.5),('share-detail',2.0),('share-detail',4.4)]
rows=[]
for l in 'en-US de-DE fr-FR es-ES es-MX it pt-BR nl-NL ja ko zh-Hans'.split():
    t=dict((x.split()[1],float(x.split()[0])-.9) for x in open(f'raw/{l}/tour.txt').read().splitlines())
    d=float(subprocess.getoutput(f'ffprobe -v error -show_entries format=duration -of csv=p=0 raw/{l}/tour.mov'));print(l,round(t['end']+.9-d,2))
    ps=[]
    for i,(k,o) in enumerate(K):
        f=f'build/k-{l}-{i}.png';subprocess.run(['ffmpeg','-v','error','-y','-ss',str(min(t[k]+o,d-.3)),'-i',f'raw/{l}/tour.mov','-frames:v','1','-vf','scale=110:-1',f]);ps+=['-i',f]
    subprocess.run(['ffmpeg','-v','error','-y',*ps,'-filter_complex',f'hstack={len(K)}',f'build/k-{l}.png']);rows+=['-i',f'build/k-{l}.png']
subprocess.run(['ffmpeg','-v','error','-y',*rows,'-filter_complex','vstack=11','build/kall.png'])
