/// Frozen transcript for `--timeline-edits-test` (see TimelineEditsHarness).
/// Captured from the pre-extraction TimelineViewController (Studio 1d,
/// 3dfa6a1) before its edit operations moved into the shared TimelineEditing
/// extension. Regenerate ONLY for a behaviour change you meant —
/// `CaptureCat --timeline-edits-test --print` — and read the line diff first.
/// Refrozen once (undo integrity, owner-approved): FOCUS drags and the Slide /
/// Curtain enables and Slide chip drags now register a step, deletes undo
/// back at their index, and Move Effect's undo restores the joined Slide — every changed line is
/// one of those (docs/ios-studio-plan.md, "Undo integrity").
enum TimelineEditsGoldens {
    static let transcript = #"""
== timeline edits (fixture: 20 s, linked zoom+tilt 2–5, zoom 8–10, blur 1–3, highlight 6–8, depth 11–13, camera 14–17, intro slide on the linked block)
   zoom[0]: 2.000000–5.000000 level=1.800000 focal=(0.400000,0.400000) anim=nil off=nil,nil
   zoom[1]: 8.000000–10.000000 level=1.500000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   tilt[0]: 2.000000–5.000000 p=12.000000 y=-4.000000 r=1.000000
   blur[0]: 1.000000–3.000000 Blur [0.300000,0.300000 0.400000x0.150000] i=0.600000 Blur
   hl[0]: 6.000000–8.000000 Highlight [0.200000,0.180000 0.420000x0.200000] o=0.550000
   focus[0]: 11.000000–13.000000 [0.280000,0.300000 0.440000x0.340000] i=0.700000
   cam[0]: 14.000000–17.000000 mode=sideBySide look=nil side=nil split=nil
   ann[0]: text 1.000000–4.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Hello"
   ann[1]: arrow 5.000000–8.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Label"
   clips:  | effective 0.000000–20.000000 | splits []
   voice[0]: 3.000000 dur=4.000000 timeline-edits-fixture-missing.m4a
   intro: Bottom start=2.000000 dur=3.000000
   curtain: Off start=0.000000 dur=1.600000
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
   playhead: 0.000000
timeline.01 add zoom at 11 s (free gap)
   undo top: Add Zoom
   events: changed
   zoom[2]: 11.000000–14.000000 level=2.000000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   selection: zoom=zoom[2] tilt=nil blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.02 add tilt at 3 s (inside a block → nearest gap)
   undo top: Add Tilt
   events: changed
   tilt[1]: 0.000000–2.000000 p=20.000000 y=0.000000 r=0.000000
   selection: zoom=nil tilt=tilt[1] blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.03 showcase at the playhead  (playhead 15.00)
   undo top: Add Showcase
   events: changed
   zoom[3]: 15.000000–18.000000 level=1.350000 focal=(0.500000,0.450000) anim=Slow Glide off=nil,nil
   tilt[2]: 15.000000–18.000000 p=10.000000 y=-6.000000 r=-2.000000
   selection: zoom=zoom[3] tilt=tilt[2] blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
   playhead: 15.000000
timeline.04 scale down at the playhead  (playhead 0.20)
   undo top: Add Scale Down
   events: changed
   zoom[4]: 5.000000–8.000000 level=0.850000 focal=(0.500000,0.500000) anim=Smooth off=nil,nil
   selection: zoom=zoom[4] tilt=nil blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
   playhead: 0.200000
timeline.05 zoom level on the 8–10 zoom
   undo top: Zoom Level
   events: changed
   zoom[1]: 8.000000–10.000000 level=2.250000 focal=(0.500000,0.500000) anim=nil off=nil,nil
timeline.06 add tilt to block (8–10 zoom)
   undo top: Add Tilt to Block
   events: changed
   tilt[3]: 8.000000–10.000000 p=20.000000 y=0.000000 r=0.000000
   selection: zoom=zoom[1] tilt=tilt[3] blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.07 add zoom to block (the 3 s tilt)
   undo top: Add Zoom to Block
   events: changed
   zoom[5]: 0.000000–2.000000 level=2.000000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   selection: zoom=zoom[5] tilt=tilt[1] blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.08 move linked block 2–5 → 3–6 (joined slide follows)
   undo top: Move Effect
   events: changed
   zoom[0]: 3.000000–6.000000 level=1.800000 focal=(0.400000,0.400000) anim=nil off=nil,nil
   tilt[0]: 3.000000–6.000000 p=12.000000 y=-4.000000 r=1.000000
   intro: Bottom start=3.000000 dur=3.000000
timeline.09 select linked block
   undo top: 
   events: changed
   selection: zoom=zoom[0] tilt=tilt[0] blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.10 ⌘D duplicate linked block
   undo top: Duplicate Effect
   events: changed
   zoom[6]: 2.000000–3.000000 level=1.800000 focal=(0.400000,0.400000) anim=nil off=nil,nil
   tilt[4]: 2.000000–3.000000 p=12.000000 y=-4.000000 r=1.000000
   selection: zoom=zoom[6] tilt=tilt[4] blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.11 select zoom only
   undo top: 
   events: changed
   selection: zoom=zoom[2] tilt=nil blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.12 ⌘D duplicate zoom
   undo top: Duplicate Zoom
   events: changed
   zoom[7]: 14.000000–15.000000 level=2.000000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   selection: zoom=zoom[7] tilt=nil blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.13 select tilt only
   undo top: 
   events: changed
   selection: zoom=nil tilt=tilt[1] blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.14 ⌘D duplicate tilt
   undo top: Duplicate Tilt
   events: changed
   tilt[5]: 10.000000–11.000000 p=20.000000 y=0.000000 r=0.000000
   selection: zoom=nil tilt=tilt[5] blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.15 delete linked block (canvas)
   undo top: Delete Effect
   events: changed
   zoom[0]: 8.000000–10.000000 level=2.250000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   zoom[1]: 11.000000–14.000000 level=2.000000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   zoom[2]: 15.000000–18.000000 level=1.350000 focal=(0.500000,0.450000) anim=Slow Glide off=nil,nil
   zoom[3]: 5.000000–8.000000 level=0.850000 focal=(0.500000,0.500000) anim=Smooth off=nil,nil
   zoom[4]: 0.000000–2.000000 level=2.000000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   zoom[5]: 2.000000–3.000000 level=1.800000 focal=(0.400000,0.400000) anim=nil off=nil,nil
   zoom[6]: 14.000000–15.000000 level=2.000000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   tilt[0]: 0.000000–2.000000 p=20.000000 y=0.000000 r=0.000000
   tilt[1]: 15.000000–18.000000 p=10.000000 y=-6.000000 r=-2.000000
   tilt[2]: 8.000000–10.000000 p=20.000000 y=0.000000 r=0.000000
   tilt[3]: 2.000000–3.000000 p=12.000000 y=-4.000000 r=1.000000
   tilt[4]: 10.000000–11.000000 p=20.000000 y=0.000000 r=0.000000
   selection: zoom=nil tilt=tilt[4] blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
   zoom[7]: <gone>
   tilt[5]: <gone>
timeline.16 remove zoom half
   undo top: Delete Zoom
   events: changed
   zoom[0]: 11.000000–14.000000 level=2.000000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   zoom[1]: 15.000000–18.000000 level=1.350000 focal=(0.500000,0.450000) anim=Slow Glide off=nil,nil
   zoom[2]: 5.000000–8.000000 level=0.850000 focal=(0.500000,0.500000) anim=Smooth off=nil,nil
   zoom[3]: 0.000000–2.000000 level=2.000000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   zoom[4]: 2.000000–3.000000 level=1.800000 focal=(0.400000,0.400000) anim=nil off=nil,nil
   zoom[5]: 14.000000–15.000000 level=2.000000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   zoom[6]: <gone>
timeline.17 remove tilt half
   undo top: Delete Tilt
   events: changed
   tilt[0]: 15.000000–18.000000 p=10.000000 y=-6.000000 r=-2.000000
   tilt[1]: 8.000000–10.000000 p=20.000000 y=0.000000 r=0.000000
   tilt[2]: 2.000000–3.000000 p=12.000000 y=-4.000000 r=1.000000
   tilt[3]: 10.000000–11.000000 p=20.000000 y=0.000000 r=0.000000
   selection: zoom=nil tilt=tilt[3] blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
   tilt[4]: <gone>
timeline.18 add blur at 4 s
   undo top: Add Blur
   events: changed
   blur[1]: 3.000000–6.000000 Blur [0.300000,0.300000 0.400000x0.150000] i=0.600000 Blur
   selection: zoom=nil tilt=nil blur=blur[1] hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.19 add highlight at 9 s
   undo top: Add Highlight
   events: changed
   hl[1]: 8.000000–11.000000 Highlight [0.200000,0.180000 0.420000x0.200000] o=0.550000
   selection: zoom=nil tilt=nil blur=nil hl=hl[1] depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.20 add depth focus at the playhead  (playhead 18.00)
   undo top: Add Depth Focus
   events: changed
   focus[1]: 18.000000–20.000000 [0.280000,0.300000 0.440000x0.340000] i=0.700000
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=focus[1] ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
   playhead: 18.000000
timeline.21 draw pixelate (preview drag-to-draw)  (playhead 0.00)
   undo top: Add Pixelate
   events: changed
   blur[2]: 0.000000–1.000000 Pixelate [0.100000,0.200000 0.300000x0.250000] i=0.600000 Pixelate
   selection: zoom=nil tilt=nil blur=blur[2] hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
   playhead: 0.000000
timeline.22 camera layout at the playhead  (playhead 0.50)
   undo top: Add Camera Layout
   events: changed
   cam[1]: 13.000000–14.000000 mode=sideBySide look=nil side=nil split=nil
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=nil cam=cam[1] voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
   playhead: 0.500000
timeline.23 cutout look  (playhead 12.00)
   undo top: Add Cutout
   events: changed
   cam[2]: 17.000000–18.000000 mode=bubble look=cutout side=nil split=nil
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=nil cam=cam[2] voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
   playhead: 12.000000
timeline.24 playhead to 5 s  (playhead 5.00)
   undo top: 
   events: changed
   playhead: 5.000000
timeline.25 FOCUS lane full: add blur refuses
   undo top:  (unchanged)
   events: -
timeline.26 select blur via FOCUS
   undo top:  (unchanged)
   events: changed
   selection: zoom=nil tilt=nil blur=blur[0] hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.27 ⌘D duplicate blur
   undo top: Duplicate Blur
   events: changed
   blur[3]: 11.000000–13.000000 Blur [0.300000,0.300000 0.400000x0.150000] i=0.600000 Blur
   selection: zoom=nil tilt=nil blur=blur[3] hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.28 select highlight via FOCUS
   undo top: 
   events: changed
   selection: zoom=nil tilt=nil blur=nil hl=hl[0] depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.29 ⌘D duplicate highlight
   undo top: Duplicate Highlight
   events: changed
   hl[2]: 13.000000–15.000000 Highlight [0.200000,0.180000 0.420000x0.200000] o=0.550000
   selection: zoom=nil tilt=nil blur=nil hl=hl[2] depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.30 select depth via FOCUS
   undo top: 
   events: changed
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=focus[0] ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.31 select camera layout via FOCUS
   undo top:  (unchanged)
   events: changed
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=nil cam=cam[0] voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.32 select nothing via FOCUS
   undo top:  (unchanged)
   events: changed
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.33 commit highlight times
   undo top: Move Highlight
   events: changed
   hl[0]: 6.500000–7.500000 Highlight [0.200000,0.180000 0.420000x0.200000] o=0.550000
timeline.34 commit focus times
   undo top: Move Depth Focus
   events: changed
   focus[0]: 11.500000–12.500000 [0.280000,0.300000 0.440000x0.340000] i=0.700000
timeline.35 commit camera times
   undo top: Move Camera Layout
   events: changed
   cam[0]: 14.500000–16.000000 mode=sideBySide look=nil side=nil split=nil
timeline.36 commit blur times
   undo top: Move Blur
   events: changed
   blur[0]: 1.250000–2.750000 Blur [0.300000,0.300000 0.400000x0.150000] i=0.600000 Blur
timeline.37 menu: Camera on Left
   undo top: Camera on Left
   events: changed
   cam[0]: 14.500000–16.000000 mode=sideBySide look=nil side=leading split=nil
timeline.38 menu: Full Height
   undo top: Full Height
   events: changed
   cam[0]: 14.500000–16.000000 mode=sideBySide look=nil side=leading split=full
timeline.39 menu: Copy Layout
   undo top: 
   events: -
timeline.40 menu: Camera on Right
   undo top: Camera on Right
   events: changed
   cam[0]: 14.500000–16.000000 mode=sideBySide look=nil side=nil split=full
timeline.41 menu: Tiles
   undo top: Tiles
   events: changed
   cam[0]: 14.500000–16.000000 mode=sideBySide look=nil side=nil split=nil
timeline.42 menu: Paste Layout on another block
   undo top: Paste Layout
   events: changed
   cam[1]: 13.000000–14.000000 mode=sideBySide look=nil side=leading split=full
timeline.43 delete focus: highlight
   undo top: Delete Highlight
   events: changed
   hl[0]: 8.000000–11.000000 Highlight [0.200000,0.180000 0.420000x0.200000] o=0.550000
   hl[1]: 13.000000–15.000000 Highlight [0.200000,0.180000 0.420000x0.200000] o=0.550000
   hl[2]: <gone>
timeline.44 delete focus: depth
   undo top: Delete Depth Focus
   events: changed
   focus[0]: 18.000000–20.000000 [0.280000,0.300000 0.440000x0.340000] i=0.700000
   focus[1]: <gone>
timeline.45 delete focus: camera
   undo top: Delete Camera Layout
   events: changed
   cam[0]: 13.000000–14.000000 mode=sideBySide look=nil side=leading split=full
   cam[1]: 17.000000–18.000000 mode=bubble look=cutout side=nil split=nil
   cam[2]: <gone>
timeline.46 delete focus: blur
   undo top: Delete Blur
   events: changed
   blur[0]: 3.000000–6.000000 Blur [0.300000,0.300000 0.400000x0.150000] i=0.600000 Blur
   blur[1]: 0.000000–1.000000 Pixelate [0.100000,0.200000 0.300000x0.250000] i=0.600000 Pixelate
   blur[2]: 11.000000–13.000000 Blur [0.300000,0.300000 0.400000x0.150000] i=0.600000 Blur
   blur[3]: <gone>
timeline.47 add text at 9.0 s
   undo top: Add Label
   events: changed
   ann[2]: text 9.000000–12.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Label"
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=ann[2] cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.48 add arrow at 10.0 s
   undo top: Add Arrow
   events: changed
   ann[3]: arrow 10.000000–13.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Label"
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=ann[3] cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.49 add callout at 11.0 s
   undo top: Add Look here
   events: changed
   ann[4]: callout 11.000000–14.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Look here"
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=ann[4] cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.50 add rectangle at 12.0 s
   undo top: Add Rectangle
   events: changed
   ann[5]: rectangle 12.000000–15.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=off bgColor=1.000,1.000,1.000,0.250 size=4.000000 text="Label"
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=ann[5] cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.51 add ellipse at 13.0 s
   undo top: Add Ellipse
   events: changed
   ann[6]: ellipse 13.000000–16.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=off bgColor=1.000,1.000,1.000,0.250 size=4.000000 text="Label"
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=ann[6] cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.52 add drawing at 14.0 s
   undo top: Add Drawing
   events: changed
   ann[7]: drawing 14.000000–20.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Label"
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=ann[7] cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.53 add tap at 19.8 s
   undo top: Add Tap
   events: changed
   ann[8]: tap 19.500000–20.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=60.000000 text="Label"
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=ann[8] cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.54 commit annotation times
   undo top: Edit Annotation Timing
   events: changed
   ann[0]: text 1.500000–3.500000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Hello"
timeline.55 select annotation off-playhead seeks  (playhead 15.00)
   undo top: 
   events: changed
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=ann[1] cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
   playhead: 5.050000
timeline.56 select annotation on-playhead stays  (playhead 6.00)
   undo top:  (unchanged)
   events: changed
   playhead: 6.000000
timeline.57 recolor selected
   undo top: Recolor Annotation
   events: changed
   ann[1]: arrow 5.000000–8.000000 color=1.000,0.500,0.000,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Label"
timeline.58 select text
   undo top: 
   events: changed
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=ann[0] cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
   playhead: 1.550000
timeline.59 font
   undo top:  (unchanged)
   events: changed
   ann[0]: text 1.500000–3.500000 color=1.000,1.000,1.000,1.000 font=Avenir weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Hello"
timeline.60 weight
   undo top:  (unchanged)
   events: changed
   ann[0]: text 1.500000–3.500000 color=1.000,1.000,1.000,1.000 font=Avenir weight=Bold bg=on bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Hello"
timeline.61 toggle background
   undo top:  (unchanged)
   events: changed
   ann[0]: text 1.500000–3.500000 color=1.000,1.000,1.000,1.000 font=Avenir weight=Bold bg=off bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Hello"
timeline.62 background color
   undo top:  (unchanged)
   events: changed
   ann[0]: text 1.500000–3.500000 color=1.000,1.000,1.000,1.000 font=Avenir weight=Bold bg=on bgColor=0.200,0.300,0.400,0.800 size=4.000000 text="Hello"
timeline.63 size on text (line width)
   undo top:  (unchanged)
   events: changed
   ann[0]: text 1.500000–3.500000 color=1.000,1.000,1.000,1.000 font=Avenir weight=Bold bg=on bgColor=0.200,0.300,0.400,0.800 size=6.000000 text="Hello"
timeline.64 select tap
   undo top:  (unchanged)
   events: changed
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=ann[8] cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
   playhead: 19.550000
timeline.65 size on a tap (ripple size)
   undo top:  (unchanged)
   events: changed
   ann[8]: tap 19.500000–20.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=40.000000 text="Label"
timeline.66 deselect annotations
   undo top:  (unchanged)
   events: changed
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.67 pill color with nothing selected
   undo top:  (unchanged)
   events: -
timeline.68 pill color is the next default  (playhead 16.00)
   undo top: Add Arrow
   events: changed
   ann[9]: arrow 16.000000–19.000000 color=0.100,0.200,0.900,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Label"
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=ann[9] cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
   playhead: 16.000000
timeline.69 delete annotation (canvas)
   undo top: Delete Annotation
   events: changed
   ann[2]: arrow 10.000000–13.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Label"
   ann[3]: callout 11.000000–14.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Look here"
   ann[4]: rectangle 12.000000–15.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=off bgColor=1.000,1.000,1.000,0.250 size=4.000000 text="Label"
   ann[5]: ellipse 13.000000–16.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=off bgColor=1.000,1.000,1.000,0.250 size=4.000000 text="Label"
   ann[6]: drawing 14.000000–20.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Label"
   ann[7]: tap 19.500000–20.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=40.000000 text="Label"
   ann[8]: arrow 16.000000–19.000000 color=0.100,0.200,0.900,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Label"
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=ann[8] cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
   ann[9]: <gone>
timeline.70 slice at 6 s
   undo top: Split Clip
   events: changed
   clips: 0.000000–6.000000 6.000000–20.000000 | effective 0.000000–6.000000 6.000000–20.000000 | splits ["6.000000"]
timeline.71 ⌘B at the playhead  (playhead 12.00)
   undo top: Split Clip (unchanged)
   events: changed
   clips: 0.000000–6.000000 6.000000–12.000000 12.000000–20.000000 | effective 0.000000–6.000000 6.000000–12.000000 12.000000–20.000000 | splits ["6.000000", "12.000000"]
   playhead: 12.000000
timeline.72 ⌘B on a cut does nothing  (playhead 12.00)
   undo top: 
   events: -
timeline.73 delete split at 12 s
   undo top: Remove Split
   events: changed
   clips: 0.000000–6.000000 6.000000–20.000000 | effective 0.000000–6.000000 6.000000–20.000000 | splits ["6.000000"]
timeline.74 select first clip
   undo top: 
   events: changed
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=clip[0] intro=false curtain=false tab=Background inspector=true
timeline.75 delete clip (Delete key)
   undo top: Delete Clip
   events: changed
   clips: 6.000000–20.000000 | effective 6.000000–20.000000 | splits []
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Background inspector=true
timeline.76 add speed range 13–16 at 2×
   undo top: Add Speed
   events: changed
   speed[0]: 13.000000–16.000000 ×2.000000
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=speed[0] clip=nil intro=false curtain=false tab=Background inspector=true
timeline.77 change speed to 3×
   undo top: Change Speed
   events: changed
   speed[0]: 13.000000–16.000000 ×3.000000
timeline.78 select speed
   undo top: 
   events: -
timeline.79 ⌘D duplicate speed
   undo top: Duplicate Speed
   events: changed
   speed[1]: 16.000000–19.000000 ×3.000000
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=speed[1] clip=nil intro=false curtain=false tab=Background inspector=true
timeline.80 delete speed (canvas)
   undo top: Delete Speed
   events: changed
   speed[0]: 16.000000–19.000000 ×3.000000
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=speed[0] clip=nil intro=false curtain=false tab=Background inspector=true
   speed[1]: <gone>
timeline.81 add speed range overlapping the copy
   undo top: Add Speed
   events: changed
   speed[1]: 13.000000–16.000000 ×0.500000
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=speed[1] clip=nil intro=false curtain=false tab=Background inspector=true
timeline.82 delete voice clip (canvas)
   undo top: Delete Voice Over
   events: changed
   voice[0]: <gone>
timeline.83 delete intro (canvas)
   undo top: Delete Slide
   events: changed
   intro: Off start=3.000000 dur=3.000000
timeline.84 enable intro (menu)
   undo top: Add Slide
   events: changed
   intro: Bottom start=3.000000 dur=3.000000
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=speed[1] clip=nil intro=true curtain=false tab=Effects inspector=true
timeline.85 resize intro
   undo top: Resize Slide
   events: changed
   intro: Bottom start=3.000000 dur=0.300000
timeline.86 move intro past the end clamps
   undo top: Move Slide
   events: changed
   intro: Bottom start=20.700000 dur=0.300000
timeline.87 open intro
   undo top: 
   events: -
timeline.88 delete intro via Delete key
   undo top: Delete Slide
   events: changed
   intro: Off start=20.700000 dur=0.300000
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=speed[1] clip=nil intro=false curtain=false tab=Effects inspector=true
timeline.89 enable curtain (menu)
   undo top: Add Curtain Unveil
   events: changed
   curtain: Top Left start=0.000000 dur=1.600000
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=speed[1] clip=nil intro=false curtain=true tab=Effects inspector=true
timeline.90 resize curtain
   undo top: 
   events: changed
   curtain: Top Left start=0.000000 dur=2.400000
timeline.91 move curtain
   undo top:  (unchanged)
   events: changed
   curtain: Top Left start=4.000000 dur=2.400000
timeline.92 open curtain
   undo top:  (unchanged)
   events: -
timeline.93 delete curtain (canvas)
   undo top: Delete Curtain Unveil
   events: changed
   curtain: Off start=4.000000 dur=2.400000
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=speed[1] clip=nil intro=false curtain=false tab=Effects inspector=true
timeline.94 auto zoom (no cursor data)
   undo top: 
   events: -
timeline.95 select zoom then Delete key
   undo top: Delete Zoom
   events: changed
   zoom[0]: 15.000000–18.000000 level=1.350000 focal=(0.500000,0.450000) anim=Slow Glide off=nil,nil
   zoom[1]: 5.000000–8.000000 level=0.850000 focal=(0.500000,0.500000) anim=Smooth off=nil,nil
   zoom[2]: 0.000000–2.000000 level=2.000000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   zoom[3]: 2.000000–3.000000 level=1.800000 focal=(0.400000,0.400000) anim=nil off=nil,nil
   zoom[4]: 14.000000–15.000000 level=2.000000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   selection: zoom=nil tilt=nil blur=nil hl=nil depth=nil ann=nil cam=nil voice=nil speed=nil clip=nil intro=false curtain=false tab=Effects inspector=true
   zoom[5]: <gone>
timeline.96 delete selection with nothing selected
   undo top: 
   events: -
unwind.01 undo: 
unwind.02 undo: Delete Zoom
   zoom[0]: 11.000000–14.000000 level=2.000000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   zoom[1]: 15.000000–18.000000 level=1.350000 focal=(0.500000,0.450000) anim=Slow Glide off=nil,nil
   zoom[2]: 5.000000–8.000000 level=0.850000 focal=(0.500000,0.500000) anim=Smooth off=nil,nil
   zoom[3]: 0.000000–2.000000 level=2.000000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   zoom[4]: 2.000000–3.000000 level=1.800000 focal=(0.400000,0.400000) anim=nil off=nil,nil
   zoom[5]: 14.000000–15.000000 level=2.000000 focal=(0.500000,0.500000) anim=nil off=nil,nil
unwind.03 undo: 
unwind.04 undo: Delete Curtain Unveil
   curtain: Top Left start=4.000000 dur=2.400000
unwind.05 undo: 
unwind.06 undo: 
unwind.07 undo: 
unwind.08 undo: Add Curtain Unveil
   curtain: Off start=4.000000 dur=2.400000
unwind.09 undo: Delete Slide
   intro: Bottom start=20.700000 dur=0.300000
unwind.10 undo: 
unwind.11 undo: Move Slide
   intro: Bottom start=3.000000 dur=0.300000
unwind.12 undo: Resize Slide
   intro: Bottom start=3.000000 dur=3.000000
unwind.13 undo: Add Slide
   intro: Off start=3.000000 dur=3.000000
unwind.14 undo: Delete Slide
   intro: Bottom start=3.000000 dur=3.000000
unwind.15 undo: Delete Voice Over
   voice[0]: 3.000000 dur=4.000000 timeline-edits-fixture-missing.m4a
unwind.16 undo: Add Speed
   speed[1]: <gone>
unwind.17 undo: Delete Speed
   speed[0]: 13.000000–16.000000 ×3.000000
   speed[1]: 16.000000–19.000000 ×3.000000
unwind.18 undo: Duplicate Speed
   speed[1]: <gone>
unwind.19 undo: 
unwind.20 undo: Change Speed
   speed[0]: 13.000000–16.000000 ×2.000000
unwind.21 undo: Add Speed
   speed[0]: <gone>
unwind.22 undo: Delete Clip
   clips: 0.000000–6.000000 6.000000–20.000000 | effective 0.000000–6.000000 6.000000–20.000000 | splits ["6.000000"]
unwind.23 undo: 
unwind.24 undo: Remove Split
   clips: 0.000000–6.000000 6.000000–12.000000 12.000000–20.000000 | effective 0.000000–6.000000 6.000000–12.000000 12.000000–20.000000 | splits ["6.000000", "12.000000"]
unwind.25 undo: 
unwind.26 undo: Split Clip
   clips: 0.000000–6.000000 6.000000–20.000000 | effective 0.000000–6.000000 6.000000–20.000000 | splits ["6.000000"]
unwind.27 undo: Split Clip
   clips:  | effective 0.000000–20.000000 | splits []
unwind.28 undo: Delete Annotation
   ann[2]: text 9.000000–12.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Label"
   ann[3]: arrow 10.000000–13.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Label"
   ann[4]: callout 11.000000–14.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Look here"
   ann[5]: rectangle 12.000000–15.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=off bgColor=1.000,1.000,1.000,0.250 size=4.000000 text="Label"
   ann[6]: ellipse 13.000000–16.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=off bgColor=1.000,1.000,1.000,0.250 size=4.000000 text="Label"
   ann[7]: drawing 14.000000–20.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Label"
   ann[8]: tap 19.500000–20.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=40.000000 text="Label"
   ann[9]: arrow 16.000000–19.000000 color=0.100,0.200,0.900,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Label"
unwind.29 undo: Add Arrow
   ann[9]: <gone>
unwind.30 undo: 
unwind.31 undo: 
unwind.32 undo: 
unwind.33 undo: 
unwind.34 undo: 
unwind.35 undo: 
unwind.36 undo: 
unwind.37 undo: 
unwind.38 undo: 
unwind.39 undo: 
unwind.40 undo: Recolor Annotation
   ann[1]: arrow 5.000000–8.000000 color=1.000,1.000,1.000,1.000 font=nil weight=Semibold bg=on bgColor=0.000,0.000,0.000,0.550 size=4.000000 text="Label"
unwind.41 undo: 
unwind.42 undo: 
unwind.43 undo: Edit Annotation Timing
   ann[0]: text 1.000000–4.000000 color=1.000,1.000,1.000,1.000 font=Avenir weight=Bold bg=on bgColor=0.200,0.300,0.400,0.800 size=6.000000 text="Hello"
unwind.44 undo: Add Tap
   ann[8]: <gone>
unwind.45 undo: Add Drawing
   ann[7]: <gone>
unwind.46 undo: Add Ellipse
   ann[6]: <gone>
unwind.47 undo: Add Rectangle
   ann[5]: <gone>
unwind.48 undo: Add Look here
   ann[4]: <gone>
unwind.49 undo: Add Arrow
   ann[3]: <gone>
unwind.50 undo: Add Label
   ann[2]: <gone>
unwind.51 undo: Delete Blur
   blur[0]: 1.250000–2.750000 Blur [0.300000,0.300000 0.400000x0.150000] i=0.600000 Blur
   blur[1]: 3.000000–6.000000 Blur [0.300000,0.300000 0.400000x0.150000] i=0.600000 Blur
   blur[2]: 0.000000–1.000000 Pixelate [0.100000,0.200000 0.300000x0.250000] i=0.600000 Pixelate
   blur[3]: 11.000000–13.000000 Blur [0.300000,0.300000 0.400000x0.150000] i=0.600000 Blur
unwind.52 undo: Delete Camera Layout
   cam[0]: 14.500000–16.000000 mode=sideBySide look=nil side=nil split=nil
   cam[1]: 13.000000–14.000000 mode=sideBySide look=nil side=leading split=full
   cam[2]: 17.000000–18.000000 mode=bubble look=cutout side=nil split=nil
unwind.53 undo: Delete Depth Focus
   focus[0]: 11.500000–12.500000 [0.280000,0.300000 0.440000x0.340000] i=0.700000
   focus[1]: 18.000000–20.000000 [0.280000,0.300000 0.440000x0.340000] i=0.700000
unwind.54 undo: Delete Highlight
   hl[0]: 6.500000–7.500000 Highlight [0.200000,0.180000 0.420000x0.200000] o=0.550000
   hl[1]: 8.000000–11.000000 Highlight [0.200000,0.180000 0.420000x0.200000] o=0.550000
   hl[2]: 13.000000–15.000000 Highlight [0.200000,0.180000 0.420000x0.200000] o=0.550000
unwind.55 undo: Paste Layout
   cam[1]: 13.000000–14.000000 mode=sideBySide look=nil side=nil split=nil
unwind.56 undo: Tiles
   cam[0]: 14.500000–16.000000 mode=sideBySide look=nil side=nil split=full
unwind.57 undo: Camera on Right
   cam[0]: 14.500000–16.000000 mode=sideBySide look=nil side=leading split=full
unwind.58 undo: 
unwind.59 undo: Full Height
   cam[0]: 14.500000–16.000000 mode=sideBySide look=nil side=leading split=nil
unwind.60 undo: Camera on Left
   cam[0]: 14.500000–16.000000 mode=sideBySide look=nil side=nil split=nil
unwind.61 undo: Move Blur
   blur[0]: 1.000000–3.000000 Blur [0.300000,0.300000 0.400000x0.150000] i=0.600000 Blur
unwind.62 undo: Move Camera Layout
   cam[0]: 14.000000–17.000000 mode=sideBySide look=nil side=nil split=nil
unwind.63 undo: Move Depth Focus
   focus[0]: 11.000000–13.000000 [0.280000,0.300000 0.440000x0.340000] i=0.700000
unwind.64 undo: Move Highlight
   hl[0]: 6.000000–8.000000 Highlight [0.200000,0.180000 0.420000x0.200000] o=0.550000
unwind.65 undo: 
unwind.66 undo: 
unwind.67 undo: 
unwind.68 undo: Duplicate Highlight
   hl[2]: <gone>
unwind.69 undo: 
unwind.70 undo: Duplicate Blur
   blur[3]: <gone>
unwind.71 undo: 
unwind.72 undo: 
unwind.73 undo: 
unwind.74 undo: Add Cutout
   cam[2]: <gone>
unwind.75 undo: Add Camera Layout
   cam[1]: <gone>
unwind.76 undo: Add Pixelate
   blur[2]: <gone>
unwind.77 undo: Add Depth Focus
   focus[1]: <gone>
unwind.78 undo: Add Highlight
   hl[1]: <gone>
unwind.79 undo: Add Blur
   blur[1]: <gone>
unwind.80 undo: Delete Tilt
   tilt[0]: 0.000000–2.000000 p=20.000000 y=0.000000 r=0.000000
   tilt[1]: 15.000000–18.000000 p=10.000000 y=-6.000000 r=-2.000000
   tilt[2]: 8.000000–10.000000 p=20.000000 y=0.000000 r=0.000000
   tilt[3]: 2.000000–3.000000 p=12.000000 y=-4.000000 r=1.000000
   tilt[4]: 10.000000–11.000000 p=20.000000 y=0.000000 r=0.000000
unwind.81 undo: Delete Zoom
   zoom[0]: 8.000000–10.000000 level=2.250000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   zoom[1]: 11.000000–14.000000 level=2.000000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   zoom[2]: 15.000000–18.000000 level=1.350000 focal=(0.500000,0.450000) anim=Slow Glide off=nil,nil
   zoom[3]: 5.000000–8.000000 level=0.850000 focal=(0.500000,0.500000) anim=Smooth off=nil,nil
   zoom[4]: 0.000000–2.000000 level=2.000000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   zoom[5]: 2.000000–3.000000 level=1.800000 focal=(0.400000,0.400000) anim=nil off=nil,nil
   zoom[6]: 14.000000–15.000000 level=2.000000 focal=(0.500000,0.500000) anim=nil off=nil,nil
unwind.82 undo: Delete Effect
   zoom[0]: 3.000000–6.000000 level=1.800000 focal=(0.400000,0.400000) anim=nil off=nil,nil
   zoom[1]: 8.000000–10.000000 level=2.250000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   zoom[2]: 11.000000–14.000000 level=2.000000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   zoom[3]: 15.000000–18.000000 level=1.350000 focal=(0.500000,0.450000) anim=Slow Glide off=nil,nil
   zoom[4]: 5.000000–8.000000 level=0.850000 focal=(0.500000,0.500000) anim=Smooth off=nil,nil
   zoom[5]: 0.000000–2.000000 level=2.000000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   zoom[6]: 2.000000–3.000000 level=1.800000 focal=(0.400000,0.400000) anim=nil off=nil,nil
   zoom[7]: 14.000000–15.000000 level=2.000000 focal=(0.500000,0.500000) anim=nil off=nil,nil
   tilt[0]: 3.000000–6.000000 p=12.000000 y=-4.000000 r=1.000000
   tilt[1]: 0.000000–2.000000 p=20.000000 y=0.000000 r=0.000000
   tilt[2]: 15.000000–18.000000 p=10.000000 y=-6.000000 r=-2.000000
   tilt[3]: 8.000000–10.000000 p=20.000000 y=0.000000 r=0.000000
   tilt[4]: 2.000000–3.000000 p=12.000000 y=-4.000000 r=1.000000
   tilt[5]: 10.000000–11.000000 p=20.000000 y=0.000000 r=0.000000
unwind.83 undo: Duplicate Tilt
   tilt[5]: <gone>
unwind.84 undo: 
unwind.85 undo: Duplicate Zoom
   zoom[7]: <gone>
unwind.86 undo: 
unwind.87 undo: Duplicate Effect
   zoom[6]: <gone>
   tilt[4]: <gone>
unwind.88 undo: 
unwind.89 undo: Move Effect
   zoom[0]: 2.000000–5.000000 level=1.800000 focal=(0.400000,0.400000) anim=nil off=nil,nil
   tilt[0]: 2.000000–5.000000 p=12.000000 y=-4.000000 r=1.000000
   intro: Bottom start=2.000000 dur=3.000000
unwind.90 undo: Add Zoom to Block
   zoom[5]: <gone>
unwind.91 undo: Add Tilt to Block
   tilt[3]: <gone>
unwind.92 undo: Zoom Level
   zoom[1]: 8.000000–10.000000 level=1.500000 focal=(0.500000,0.500000) anim=nil off=nil,nil
unwind.93 undo: Add Scale Down
   zoom[4]: <gone>
unwind.94 undo: Add Showcase
   zoom[3]: <gone>
   tilt[2]: <gone>
unwind.95 undo: Add Tilt
   tilt[1]: <gone>
unwind.96 undo: Add Zoom
   zoom[2]: <gone>
== unwound 96 step(s); canUndo=false
"""#
}
