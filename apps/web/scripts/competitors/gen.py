import json, glob, sys, os
D=os.path.dirname(__file__)
items=[]
for f in sorted(glob.glob(os.path.join(D,'batch-*.json'))):
    for it in json.load(open(f)):
        # Batches overlap (CANVID and Recordly were researched twice); the
        # first batch's record wins.
        if it['slug'] not in {x['slug'] for x in items}: items.append(it)
CAT={
 'screen-studio':'demo','focusee':'demo','rapidemo':'demo','screen-charm':'demo','cursorful':'demo','tella':'demo',
 'loom':'async','cap':'async','zight':'async','vidyard':'async','screencastify':'async','jumpshare':'async','guidde':'async','screenpal':'async',
 'camtasia':'editor','screenflow':'editor','descript':'editor','movavi-screen-recorder':'editor','democreator':'editor','clipchamp':'editor','veed':'editor',
 'cleanshot-x':'capture','snagit':'capture','bandicam':'capture',
 'obs-studio':'free','kap':'free','quicktime':'free','screenity':'free','sharex':'free',
}
ORDER=['screen-studio','focusee','rapidemo','screen-charm','tella','cursorful',
 'loom','cap','zight','vidyard','screenpal','screencastify','jumpshare','guidde',
 'camtasia','screenflow','descript','democreator','movavi-screen-recorder','clipchamp','veed',
 'cleanshot-x','snagit','bandicam',
 'obs-studio','quicktime','kap','screenity','sharex']
# Hand-verified corrections to agent research (2026-10-06).
# Never publish these as source links: apowersoft.com/store/ carried what looks
# like injected skimming script (hidden onload + base64 new Function, spoofed
# analytics host) on 2026-10-06; download mirrors are not primary sources.
BLOCKED_SOURCES=('apowersoft.com/store/', 'filehippo.com', 'softpedia.com')
TEXT_PATCHES={
 'cap': ('on-device captions and an official MCP server.', "on-device captions and an official MCP server (Cap's manages recordings, while CaptureCat's also records and edits)."),
 'awesome-screenshot': ('Awesome Screenshot covers full-page screenshots, which CaptureCat does not.', 'Awesome Screenshot is a lightweight browser extension for annotated screenshots; CaptureCat captures full-height web pages by URL only on Pro.'),
 'descript': ('and its share links track watch time and retention.', 'and its Pro share links track watch time and retention.'),
}
PATCHES={
 # cap.so/agents: 76 tools manage Caps; "Screen capture, uploads ... stay in the CLI".
 'cap': {'mcp': 'Official MCP; manages, no record/edit'},
 # Tella's docs don't say where transcription runs; the agent assumed cloud.
 'tella': {'captions': 'Auto-captions (location not stated)'},
 # icecreamapps.com only served GBP prices to the researcher.
 'icecream-screen-recorder': {'price': 'Free · £19.95/yr or £49.99 lifetime (UK)'},
}
KEYS=['autoZoom','cursorEffects','captions','mcp','shareAnalytics','freeVersion','openSource','platform','price']
CAT_ORDER=['demo','async','editor','capture','free','interactive']
def cat_of(it): return CAT.get(it['slug']) or it.get('category') or 'demo'
def rank(it):
    s=it['slug']
    return (CAT_ORDER.index(cat_of(it)), ORDER.index(s) if s in ORDER else 100, it['name'].lower())
items.sort(key=rank)
out=[]
missing=[]
for it in items:
    s=it['slug']
    cat=cat_of(it)
    if s not in CAT and not it.get('category'): missing.append(s)
    it.update(PATCHES.get(s,{}))
    if s in TEXT_PATCHES:
        a,b=TEXT_PATCHES[s]
        assert a in it['differentiator'], s
        it['differentiator']=it['differentiator'].replace(a,b)
    # Researchers were served UK prices by some sites; say so instead of implying USD.
    if isinstance(it.get('price'),str) and '£' in it['price'] and not any(t in it['price'] for t in ('UK','GBP')):
        it['price']=it['price']+' (UK)'
    feats=[it.get(k) for k in KEYS]
    srcs=[]
    for v in (it.get('sources') or {}).values():
        for u in (v if isinstance(v,list) else [v]):
            if u and u not in srcs and not any(b in u for b in BLOCKED_SOURCES): srcs.append(u)
    o={'slug':s,'name':it['name'],'website':it['website'],'category':cat,'summary':it['summary'],
       'differentiator':it['differentiator'],'pickThemWhen':it['pickThemWhen'],'strengths':it['strengths'],
       'tradeoffs':it['tradeoffs'],'features':feats,'switchTip':it['switchTip']}
    if it.get('faqExtra'):
        fe=dict(it['faqExtra'])
        fe['answer']=fe['answer'].replace(' by Siddharth Vaddem','')
        o['faqExtra']=fe
    o['sources']=srcs
    out.append(o)
body=json.dumps(out,indent=2,ensure_ascii=False)
ts='''import type { Competitor } from "./pseo-content";

/**
 * Every competitor on /compare and /alternatives, generated from sourced
 * research and reviewed by hand. Checked against each product's own site on
 * FACTS_CHECKED (pseo-content.ts). `features` cells align 1:1 with
 * FEATURE_ROWS: auto zoom, cursor, captions, MCP, share analytics, free tier,
 * open source, platform, price. null means unverified ("check their site").
 *
 * When a fact changes, change the cell AND its source, and bump FACTS_CHECKED.
 */
export const COMPETITORS: Competitor[] = ''' + body + ';\n'
open(sys.argv[1],'w').write(ts)
print(len(out),'competitors; uncategorised:',missing)
