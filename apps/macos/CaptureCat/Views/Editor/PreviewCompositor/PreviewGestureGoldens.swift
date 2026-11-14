/// Frozen transcript for `--preview-gesture-test` (see PreviewGestureHarness).
/// Captured from the pre-extraction PreviewInteractionView (Studio 1c,
/// 1f11826) before its hit math moved into PreviewHitMath. Regenerate ONLY for
/// a behaviour change you meant — `CaptureCat --preview-gesture-test --print`
/// — and read the line diff first.
enum PreviewGestureGoldens {
    static let transcript = #"""
== annotations 960x540
   ctx: content=[48.000000,48.000000 864.000000x444.000000] video=[76.800000,-0.000000 710.400000x444.000000] zoom=1.000000 anchor=(480.000000,270.000000) off=(0.000000,0.000000)
   chrome: cam=nil sub=nil wm=nil stack=nil
   ann.R: (0.100000,0.100000)→(0.300000,0.300000)
   ann.E: (0.400000,0.100000)→(0.550000,0.300000)
   ann.A: (0.650000,0.150000)→(0.850000,0.300000)
   ann.T: (0.500000,0.550000)→(0.650000,0.550000) text="Hello world"
   ann.P: (0.750000,0.720000)→(0.750000,0.720000)
   ann.C: (0.080000,0.620000)→(0.220000,0.780000) text="Note"
   ann.D: (0.450000,0.850000)→(0.450000,0.850000) strokes=1 points=[3] last=(0.500000,0.820000)
   settings: cam=Bottom Right custom=nil wm=1.000000,1.000000 sub=Bottom custom=nil card=Center custom=nil stack=nil
   selection: ann=nil hl=nil blur=nil depth=nil zoom=nil
   ui: editing=nil dragging=false toolbarAnchor=nil undo=
annotations.01 rect body move  (from (266.880000,136.800000) drag=true)
   events: selAnn=R, selBlur=nil, selHl=nil, selDepth=nil, dragEnded
   ann.R: (0.156306,0.156306)→(0.356306,0.356306)
   selection: ann=R hl=nil blur=nil depth=nil zoom=nil
   ui: editing=nil dragging=false toolbarAnchor=[225.840000,107.400000 162.080000x108.800000] undo=
annotations.02 rect TL handle  (from (235.840000,117.400000) drag=true)
   events: selAnn=R, selBlur=nil, selHl=nil, selDepth=nil, dragEnded
   ann.R: (0.135191,0.133784)→(0.356306,0.356306)
   ui: editing=nil dragging=false toolbarAnchor=[210.840000,97.400000 177.080000x118.800000] undo=
annotations.03 rect BR handle  (from (377.920000,206.200000) drag=true)
   events: selAnn=R, selBlur=nil, selHl=nil, selDepth=nil, dragEnded
   ann.R: (0.135191,0.133784)→(0.370383,0.401351)
   ui: editing=nil dragging=false toolbarAnchor=[210.840000,97.400000 187.080000x138.800000] undo=
annotations.04 ellipse TR handle  (from (515.520000,92.400000) drag=true)
   events: selAnn=E, selBlur=nil, selHl=nil, selDepth=nil, dragEnded
   ann.E: (0.400000,0.081982)→(0.566892,0.300000)
   selection: ann=E hl=nil blur=nil depth=nil zoom=nil
   ui: editing=nil dragging=false toolbarAnchor=[398.960000,74.400000 138.560000x116.800000] undo=
annotations.05 ellipse BL handle  (from (408.960000,181.200000) drag=true)
   events: selAnn=E, selBlur=nil, selHl=nil, selDepth=nil, dragEnded
   ann.E: (0.391554,0.081982)→(0.566892,0.320270)
   ui: editing=nil dragging=false toolbarAnchor=[392.960000,74.400000 144.560000x125.800000] undo=
annotations.06 arrow head  (from (728.640000,181.200000) drag=true)
   events: selAnn=A, selBlur=nil, selHl=nil, selDepth=nil, dragEnded
   ann.A: (0.650000,0.150000)→(0.878153,0.322523)
   selection: ann=A hl=nil blur=nil depth=nil zoom=nil
   ui: editing=nil dragging=false toolbarAnchor=[570.560000,98.600000 194.080000x108.600000] undo=
annotations.07 arrow tail  (from (586.560000,114.600000) drag=true)
   events: selAnn=A, selBlur=nil, selHl=nil, selDepth=nil, dragEnded
   ann.A: (0.635923,0.161261)→(0.878153,0.322523)
   ui: editing=nil dragging=false toolbarAnchor=[560.560000,103.600000 204.080000x103.600000] undo=
annotations.08 arrow body clamps at the video edge  (from (662.600000,155.400000) drag=true)
   events: selAnn=A, selBlur=nil, selHl=nil, selDepth=nil, dragEnded
   ann.A: (0.757770,0.161261)→(1.000000,0.322523)
   ui: editing=nil dragging=false toolbarAnchor=[647.120000,103.600000 204.080000x103.600000] undo=
annotations.09 text body  (from (480.000000,292.200000) drag=true)
   events: selAnn=T, selBlur=nil, selHl=nil, selDepth=nil, dragEnded
   ann.T: (0.542230,0.504955)→(0.650000,0.550000) text="Hello world"
   selection: ann=T hl=nil blur=nil depth=nil zoom=nil
   ui: editing=nil dragging=false toolbarAnchor=[444.857747,247.700000 130.284505x49.000000] undo=
annotations.10 tap body  (from (657.600000,367.680000) drag=true)
   events: selAnn=P, selBlur=nil, selHl=nil, selDepth=nil, dragEnded
   ann.P: (0.714809,0.753784)→(0.750000,0.720000)
   selection: ann=P hl=nil blur=nil depth=nil zoom=nil
   ui: editing=nil dragging=false toolbarAnchor=[608.600000,358.680000 48.000000x48.000000] undo=
annotations.11 callout body  (from (231.360000,358.800000) drag=true)
   events: selAnn=C, selBlur=nil, selHl=nil, selDepth=nil, dragEnded
   ann.C: (0.101115,0.642523)→(0.241115,0.802523) text="Note"
   selection: ann=C hl=nil blur=nil depth=nil zoom=nil
   ui: editing=nil dragging=false toolbarAnchor=[180.632000,317.280000 131.456000x103.040000] undo=
annotations.12 click drawing ink selects it  (at (444.480000,425.400000))
   events: selAnn=D, selBlur=nil, selHl=nil, selDepth=nil, dragEnded
   selection: ann=D hl=nil blur=nil depth=nil zoom=nil
   ui: editing=nil dragging=false toolbarAnchor=[396.960000,391.200000 95.040000x46.200000] undo=
annotations.13 pen stroke on the selected drawing  (from (337.920000,225.600000) drag=true)
   events: dragEnded
   ann.D: (0.450000,0.850000)→(0.450000,0.850000) strokes=2 points=[3, 3] last=(0.333784,0.422523)
   ui: editing=nil dragging=false toolbarAnchor=[325.920000,213.600000 166.080000x223.800000] undo=
annotations.14 click text while the drawing is selected adds a pen dot  (at (510.000000,272.200000))
   events: dragEnded
   ann.D: (0.450000,0.850000)→(0.450000,0.850000) strokes=3 points=[3, 3, 1] last=(0.542230,0.504955)
   ui: editing=nil dragging=false toolbarAnchor=[325.920000,213.600000 196.080000x223.800000] undo=
annotations.15 double-click text edits in place  (at (510.000000,272.200000) x2)
   events: selAnn=T, selBlur=nil, selHl=nil, selDepth=nil, dragEnded
   selection: ann=T hl=nil blur=nil depth=nil zoom=nil
   ui: editing=T dragging=false toolbarAnchor=[444.857747,247.700000 130.284505x49.000000] undo=
annotations.16 click-away commits the edit  (at (778.368000,292.200000))
   events: dragEnded
   ui: editing=nil dragging=false toolbarAnchor=[444.857747,247.700000 130.284505x49.000000] undo=
annotations.17 click empty card: below drag threshold  (from (778.368000,292.200000) drag=true)
   events: selAnn=nil, dragEnded
   selection: ann=nil hl=nil blur=nil depth=nil zoom=nil
   ui: editing=nil dragging=false toolbarAnchor=nil undo=
annotations.18 card placement drag  (from (778.368000,292.200000) drag=true)
   events: dragEnded
   ctx: content=[50.925000,50.548148 864.000000x444.000000] video=[132.375000,26.118519 710.400000x444.000000] zoom=1.000000 anchor=(485.850000,270.000000) off=(0.000000,0.000000)
   settings: cam=Bottom Right custom=nil wm=1.000000,1.000000 sub=Bottom custom=nil card=Center custom=0.560937,0.553086 stack=nil
annotations.19 card back to centre (magnetism)  (from (836.868000,320.866667) drag=true)
   events: dragEnded
   ctx: content=[48.000000,48.000000 864.000000x444.000000] video=[76.800000,-0.000000 710.400000x444.000000] zoom=1.000000 anchor=(480.000000,270.000000) off=(0.000000,0.000000)
   settings: cam=Bottom Right custom=nil wm=1.000000,1.000000 sub=Bottom custom=nil card=Center custom=nil stack=nil
annotations.20 select rect  (at (304.380000,166.800000))
   events: selAnn=R, selBlur=nil, selHl=nil, selDepth=nil, dragEnded
   selection: ann=R hl=nil blur=nil depth=nil zoom=nil
   ui: editing=nil dragging=false toolbarAnchor=[210.840000,97.400000 187.080000x138.800000] undo=
annotations.21 esc deselects everything
   events: selAnn=nil
   selection: ann=nil hl=nil blur=nil depth=nil zoom=nil
   ui: editing=nil dragging=false toolbarAnchor=nil undo=
annotations.22 playing: annotations are not hit, the card drags  (from (304.380000,166.800000) drag=true)
   events: dragEnded
   ctx: content=[53.900000,48.000000 864.000000x444.000000] video=[188.900000,-0.000000 710.400000x444.000000] zoom=1.000000 anchor=(491.800000,270.000000) off=(0.000000,0.000000)
   settings: cam=Bottom Right custom=nil wm=1.000000,1.000000 sub=Bottom custom=nil card=Center custom=0.622917,0.500000 stack=nil
== regions 960x540
   ctx: content=[48.000000,48.000000 864.000000x444.000000] video=[76.800000,-0.000000 710.400000x444.000000] zoom=1.000000 anchor=(480.000000,270.000000) off=(0.000000,0.000000)
   chrome: cam=nil sub=nil wm=nil stack=nil
   blur.B: [0.080000,0.080000 0.300000x0.200000] intensity=0.600000
   hl.H: [0.550000,0.100000 0.300000x0.250000] opacity=0.550000
   focus.F: [0.300000,0.550000 0.400000x0.300000] intensity=0.700000
   settings: cam=Bottom Right custom=nil wm=1.000000,1.000000 sub=Bottom custom=nil card=Center custom=nil stack=nil
   selection: ann=nil hl=nil blur=nil depth=nil zoom=nil
   ui: editing=nil dragging=false toolbarAnchor=nil undo=
regions.01 blur body selects + moves  (from (288.192000,127.920000) drag=true)
   events: selBlur=B, selHl=nil, selDepth=nil, dragEnded
   blur.B: [0.094077,0.102523 0.300000x0.200000] intensity=0.600000
   selection: ann=nil hl=nil blur=B depth=nil zoom=nil
regions.02 blur TL corner  (from (191.632000,93.520000) drag=true)
   events: selBlur=B, selHl=nil, selDepth=nil, dragEnded
   blur.B: [0.080000,0.080000 0.314077x0.222523] intensity=0.600000
regions.03 blur value pill  (from (293.192000,203.320000) drag=true)
   events: selBlur=B, selHl=nil, selDepth=nil, dragEnded
   blur.B: [0.080000,0.080000 0.314077x0.222523] intensity=0.658000
regions.04 focus body selects + moves  (from (480.000000,358.800000) drag=true)
   events: selDepth=F, selHl=nil, selBlur=nil, dragEnded
   focus.F: [0.271847,0.617568 0.400000x0.300000] intensity=0.700000
   selection: ann=nil hl=nil blur=nil depth=F zoom=nil
regions.05 focus right edge  (from (602.080000,388.800000) drag=true)
   events: selDepth=F, selHl=nil, selBlur=nil, dragEnded
   focus.F: [0.271847,0.617568 0.456306x0.300000] intensity=0.700000
regions.06 focus value pill (tucked inside)  (from (480.000000,476.400000) drag=true)
   events: selDepth=F, selHl=nil, selBlur=nil, dragEnded
   focus.F: [0.271847,0.617568 0.456306x0.300000] intensity=1.000000
regions.07 highlight body selects + moves  (from (622.080000,147.900000) drag=true)
   events: selHl=H, selBlur=nil, dragEnded
   hl.H: [0.592230,0.145045 0.300000x0.250000] opacity=0.550000
   selection: ann=nil hl=H blur=nil depth=F zoom=nil
regions.08 highlight BR corner  (from (758.640000,223.400000) drag=true)
   events: selHl=H, selBlur=nil, dragEnded
   hl.H: [0.592230,0.145045 0.335191x0.283784] opacity=0.550000
regions.09 highlight top edge  (from (664.580000,112.400000) drag=true)
   events: selHl=H, selBlur=nil, dragEnded
   hl.H: [0.592230,0.100000 0.335191x0.328829] opacity=0.550000
regions.10 highlight value pill  (from (664.580000,259.400000) drag=true)
   events: selHl=H, selBlur=nil, dragEnded
   hl.H: [0.592230,0.100000 0.335191x0.328829] opacity=0.100000
regions.11 card click deselects every region  (at (231.360000,247.800000))
   events: selHl=nil, selDepth=nil, dragEnded
   selection: ann=nil hl=nil blur=nil depth=nil zoom=nil
regions.12 reselect highlight  (at (664.580000,165.400000))
   events: selHl=H, selBlur=nil, dragEnded
   selection: ann=nil hl=H blur=nil depth=nil zoom=nil
regions.13 highlight left edge clamps at 0  (from (545.520000,165.400000) drag=true)
   events: selHl=H, selBlur=nil, dragEnded
   hl.H: [0.000000,0.100000 0.927421x0.328829] opacity=0.100000
regions.14 highlight right edge stops at the minimum size  (from (783.640000,165.400000) drag=true)
   events: selHl=H, selBlur=nil, dragEnded
   hl.H: [0.000000,0.100000 0.040000x0.328829] opacity=0.100000
== zoom 960x540
   ctx: content=[48.000000,48.000000 864.000000x444.000000] video=[76.800000,-0.000000 710.400000x444.000000] zoom=1.800000 anchor=(350.400000,216.000000) off=(0.050000,-0.030000)
   chrome: cam=nil sub=nil wm=nil stack=nil
   ann.R: (0.300000,0.300000)→(0.450000,0.450000)
   zoom.Z: focal=(0.350000,0.400000) off=0.050000,-0.030000
   settings: cam=Bottom Right custom=nil wm=1.000000,1.000000 sub=Bottom custom=nil card=Center custom=nil stack=nil
   selection: ann=nil hl=nil blur=nil depth=nil zoom=Z
   ui: editing=nil dragging=false toolbarAnchor=nil undo=
zoom.01 focal target drag  (from (439.872000,217.080000) drag=true)
   events: focal=(0.361730,0.412513), focal=(0.379802,0.431789), dragEnded
   ctx: content=[48.000000,48.000000 864.000000x444.000000] video=[76.800000,-0.000000 710.400000x444.000000] zoom=1.800000 anchor=(376.148722,233.165814) off=(0.050000,-0.030000)
   zoom.Z: focal=(0.379802,0.431789) off=0.050000,-0.030000
zoom.02 focal target clamps to the video  (from (457.381131,228.752754) drag=true)
   events: focal=(0.000000,0.000000), dragEnded
   ctx: content=[48.000000,48.000000 864.000000x444.000000] video=[76.800000,-0.000000 710.400000x444.000000] zoom=1.800000 anchor=(48.000000,0.000000) off=(0.050000,-0.030000)
   zoom.Z: focal=(0.000000,0.000000) off=0.050000,-0.030000
zoom.03 rect body under zoom  (from (713.760000,369.900000) drag=true)
   events: selAnn=R, selBlur=nil, selHl=nil, selDepth=nil, dragEnded
   ann.R: (0.319551,0.312513)→(0.469551,0.462513)
   selection: ann=R hl=nil blur=nil depth=nil zoom=nil
   ui: editing=nil dragging=false toolbarAnchor=[576.856000,318.160000 227.808000x155.880000] undo=
zoom.04 block excursion drag  (from (426.048000,270.000000) drag=true)
   events: selAnn=nil, dragEnded
   ctx: content=[48.000000,48.000000 864.000000x444.000000] video=[76.800000,-0.000000 710.400000x444.000000] zoom=1.800000 anchor=(48.000000,0.000000) off=(0.102083,0.007037)
   zoom.Z: focal=(0.000000,0.000000) off=0.102083,0.007037
   selection: ann=nil hl=nil blur=nil depth=nil zoom=nil
   ui: editing=nil dragging=false toolbarAnchor=nil undo=
zoom.05 block excursion back home (rest magnetism)  (from (476.048000,290.000000) drag=true)
   events: dragEnded
   ctx: content=[48.000000,48.000000 864.000000x444.000000] video=[76.800000,-0.000000 710.400000x444.000000] zoom=1.800000 anchor=(48.000000,0.000000) off=(0.000000,0.000000)
   zoom.Z: focal=(0.000000,0.000000) off=nil,nil
== tilt 960x540
   ctx: content=[48.000000,48.000000 864.000000x444.000000] video=[76.800000,-0.000000 710.400000x444.000000] zoom=1.000000 anchor=(480.000000,270.000000) off=(0.000000,0.000000)
   chrome: cam=nil sub=nil wm=nil stack=nil
   ann.R: (0.350000,0.350000)→(0.600000,0.600000)
   ann.T: (0.200000,0.800000)→(0.300000,0.800000) text="Tilted"
   settings: cam=Bottom Right custom=nil wm=1.000000,1.000000 sub=Bottom custom=nil card=Center custom=nil stack=nil
   selection: ann=nil hl=nil blur=nil depth=nil zoom=nil
   ui: editing=nil dragging=false toolbarAnchor=nil undo=
tilt.01 rect body under tilt  (from (462.240000,258.900000) drag=true)
   events: selAnn=R, selBlur=nil, selHl=nil, selDepth=nil, dragEnded
   ann.R: (0.393399,0.380202)→(0.643399,0.630202)
   selection: ann=R hl=nil blur=nil depth=nil zoom=nil
   ui: editing=nil dragging=false toolbarAnchor=[394.270637,206.809597 197.600000x131.000000] undo=
tilt.02 rect BR under tilt  (from (581.870637,327.809597) drag=true)
   events: selAnn=R, selBlur=nil, selHl=nil, selDepth=nil, dragEnded
   ann.R: (0.393399,0.380202)→(0.630544,0.639334)
   ui: editing=nil dragging=false toolbarAnchor=[394.270637,206.809597 188.467694x135.054700] undo=
tilt.03 text under tilt  (from (266.880000,403.200000) drag=true)
   events: selAnn=T, selBlur=nil, selHl=nil, selDepth=nil, dragEnded
   ann.T: (0.225731,0.776292)→(0.300000,0.800000) text="Tilted"
   selection: ann=T hl=nil blur=nil depth=nil zoom=nil
   ui: editing=nil dragging=false toolbarAnchor=[243.326176,368.173737 83.665761x49.000000] undo=
tilt.04 card drag under tilt  (from (728.640000,114.600000) drag=true)
   events: selAnn=nil, dragEnded
   ctx: content=[52.604616,51.330381 864.000000x444.000000] video=[164.287707,34.136402 710.400000x444.000000] zoom=1.000000 anchor=(491.000391,265.814385) off=(0.000000,0.000000)
   settings: cam=Bottom Right custom=nil wm=1.000000,1.000000 sub=Bottom custom=nil card=Center custom=0.595930,0.569383 stack=nil
   selection: ann=nil hl=nil blur=nil depth=nil zoom=nil
   ui: editing=nil dragging=false toolbarAnchor=nil undo=
== chrome 960x540
   ctx: content=[48.000000,48.000000 864.000000x444.000000] video=[76.800000,-0.000000 710.400000x444.000000] zoom=1.000000 anchor=(480.000000,270.000000) off=(0.000000,0.000000)
   chrome: cam=[872.967033,452.967033 79.120879x79.120879] sub=[346.000000,468.000000 268.000000x52.000000] wm=[820.000000,484.000000 120.000000x36.000000] stack=nil
   settings: cam=Bottom Right custom=nil wm=1.000000,1.000000 sub=Bottom custom=nil card=Center custom=nil stack=nil
   selection: ann=nil hl=nil blur=nil depth=nil zoom=nil
   ui: editing=nil dragging=false toolbarAnchor=nil undo=
chrome.01 watermark drag  (from (880.000000,502.000000) drag=true)
   events: dragEnded
   chrome: cam=[872.967033,452.967033 79.120879x79.120879] sub=[346.000000,468.000000 268.000000x52.000000] wm=[620.000000,384.000000 120.000000x36.000000] stack=nil
   settings: cam=Bottom Right custom=nil wm=0.750000,0.784483 sub=Bottom custom=nil card=Center custom=nil stack=nil
chrome.02 camera drag  (from (912.527473,492.527473) drag=true)
   events: dragEnded
   chrome: cam=[772.967033,392.967033 79.120879x79.120879] sub=[346.000000,468.000000 268.000000x52.000000] wm=[620.000000,384.000000 120.000000x36.000000] stack=nil
   settings: cam=Bottom Right custom=0.884400,0.865185 wm=0.750000,0.784483 sub=Bottom custom=nil card=Center custom=nil stack=nil
chrome.03 camera corner magnetism  (from (812.527473,432.527473) drag=true)
   events: dragEnded
   chrome: cam=[7.912088,7.912088 79.120879x79.120879] sub=[346.000000,468.000000 268.000000x52.000000] wm=[620.000000,384.000000 120.000000x36.000000] stack=nil
   settings: cam=Top Left custom=nil wm=0.750000,0.784483 sub=Bottom custom=nil card=Center custom=nil stack=nil
chrome.04 subtitle drag  (from (480.000000,494.000000) drag=true)
   events: dragEnded
   chrome: cam=[7.912088,7.912088 79.120879x79.120879] sub=[346.000000,348.000000 268.000000x52.000000] wm=[620.000000,384.000000 120.000000x36.000000] stack=nil
   settings: cam=Top Left custom=nil wm=0.750000,0.784483 sub=Bottom custom=0.500000,0.732143 card=Center custom=nil stack=nil
chrome.05 subtitle anchor magnetism  (from (480.000000,374.000000) drag=true)
   events: dragEnded
   chrome: cam=[7.912088,7.912088 79.120879x79.120879] sub=[346.000000,468.000000 268.000000x52.000000] wm=[620.000000,384.000000 120.000000x36.000000] stack=nil
   settings: cam=Top Left custom=nil wm=0.750000,0.784483 sub=Bottom custom=nil card=Center custom=nil stack=nil
chrome.06 watermark edge magnetism  (from (680.000000,402.000000) drag=true)
   events: dragEnded
   chrome: cam=[7.912088,7.912088 79.120879x79.120879] sub=[346.000000,468.000000 268.000000x52.000000] wm=[820.000000,484.000000 120.000000x36.000000] stack=nil
   settings: cam=Top Left custom=nil wm=1.000000,1.000000 sub=Bottom custom=nil card=Center custom=nil stack=nil
== stack 540x960
   ctx: content=[48.000000,48.000000 444.000000x864.000000] video=[0.000000,293.250000 444.000000x277.500000] zoom=1.000000 anchor=(270.000000,480.000000) off=(0.000000,0.000000)
   chrome: cam=[48.000000,48.000000 444.000000x355.622400] sub=nil wm=nil stack=[48.000000,48.000000 444.000000x355.622400] seam=403.622400
   settings: cam=Bottom Right custom=nil wm=1.000000,1.000000 sub=Bottom custom=nil card=Center custom=nil stack=nil
   selection: ann=nil hl=nil blur=nil depth=nil zoom=nil
   ui: editing=nil dragging=false toolbarAnchor=nil undo=
stack.01 stack seam drag  (from (270.000000,403.622400) drag=true)
   events: dragEnded
   chrome: cam=[48.000000,48.000000 444.000000x415.622400] sub=nil wm=nil stack=[48.000000,48.000000 444.000000x415.622400] seam=463.622400
   settings: cam=Bottom Right custom=nil wm=1.000000,1.000000 sub=Bottom custom=nil card=Center custom=nil stack=0.490862
   ui: editing=nil dragging=false toolbarAnchor=nil undo=Camera Height
stack.02 stacked camera row is inert  (at (270.000000,225.811200))
   events: dragEnded
== blurDraw 960x540
   ctx: content=[48.000000,48.000000 864.000000x444.000000] video=[76.800000,-0.000000 710.400000x444.000000] zoom=1.000000 anchor=(480.000000,270.000000) off=(0.000000,0.000000)
   chrome: cam=nil sub=nil wm=nil stack=nil
   settings: cam=Bottom Right custom=nil wm=1.000000,1.000000 sub=Bottom custom=nil card=Center custom=nil stack=nil
   selection: ann=nil hl=nil blur=nil depth=nil zoom=nil
   ui: editing=nil dragging=false toolbarAnchor=nil undo=
blurDraw.01 armed draw: drag out a region  (from (266.880000,136.800000) drag=true)
   events: create=[0.200000,0.200000 0.300000x0.250000] Pixelate, dragEnded
blurDraw.02 armed draw: a click grows to the minimum  (at (551.040000,314.400000))
   events: create=[0.560000,0.560000 0.080000x0.080000] Blur, dragEnded
blurDraw.03 armed draw: esc disarms
   events: -
blurDraw.04 after disarm a click is an ordinary card click  (at (551.040000,314.400000))
   events: dragEnded
blurDraw.05 armed draw past the edge is clipped to the video  (from (764.160000,447.600000) drag=true)
   events: create=[0.900000,0.900000 0.100000x0.100000] Pixelate, dragEnded
"""#
}
