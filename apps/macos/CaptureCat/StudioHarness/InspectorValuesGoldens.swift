// The frozen Mac inspector-values transcript (`--inspector-values-test`), the
// reference the iOS `--inspector` gate is held to. Regenerate with
// `CaptureCat --inspector-values-test <dir> --refreeze` and review the diff —
// never refreeze to make a red gate green.
enum InspectorValuesGoldens {
    static let transcript = #"""
    == inspector values (fixture: 20 s window take with a device segment, camera, shortcut keystrokes; zoom 2–5, tilt 8–10, highlight 6–8, depth 11–13, blur 1–3; text, rectangle, drawing, tap, arrow; two captions)
    select none
      selection: zoom=- tilt=- highlight=- depth=- blur=- annotation=- tab=Background
    [Background] background.type choose 2
      settings.backgroundType="Solid Color"
      visible: background.blur,background.brightness,background.contrast,background.corners,background.deviceFrame,background.grain,background.halftone,background.hue,background.menuBar,background.menuBarCaption,background.padding,background.pixelate,background.placement,background.placementReset,background.saturation,background.shadow,background.shadowOpacity,background.shape,background.solid,background.tint,background.tintAmount,background.type,background.vignette
    [Background] background.solid color 0.200,0.400,0.600,1.000
      settings.solidColor.blue=0.600000
      settings.solidColor.green=0.400000
      settings.solidColor.red=0.200000
    [Background] background.type choose 0
      settings.backgroundType="Gradient"
      visible: background.angle,background.blur,background.brightness,background.contrast,background.corners,background.deviceFrame,background.gradientEnd,background.gradientStart,background.grain,background.halftone,background.hue,background.menuBar,background.menuBarCaption,background.padding,background.pixelate,background.placement,background.placementReset,background.saturation,background.shadow,background.shadowOpacity,background.shape,background.tint,background.tintAmount,background.type,background.vignette
    [Background] background.gradientStart color 0.900,0.100,0.300,1.000
      settings.gradientStartColor.blue=0.300000
      settings.gradientStartColor.green=0.100000
      settings.gradientStartColor.red=0.900000
    [Background] background.gradientEnd color 0.100,0.200,0.900,0.800
      settings.gradientEndColor.blue=0.900000
      settings.gradientEndColor.green=0.200000
      settings.gradientEndColor.opacity=0.800000
      settings.gradientEndColor.red=0.100000
    [Background] background.angle slider 91.500000
      settings.gradientAngle=90.000000
    [Background] background.blur slider 0.366000
      settings.backgroundBlur=0.360000
      visible: background.angle,background.blur,background.brightness,background.contrast,background.corners,background.deviceFrame,background.gradientEnd,background.gradientStart,background.grain,background.halftone,background.hue,background.menuBar,background.menuBarCaption,background.padding,background.pixelate,background.placement,background.placementReset,background.resetLook,background.saturation,background.shadow,background.shadowOpacity,background.shape,background.tint,background.tintAmount,background.type,background.vignette
    [Background] background.pixelate slider 0.206000
      settings.backgroundPixelate=0.200000
    [Background] background.halftone slider 0.426000
      settings.backgroundHalftone=0.420000
    [Background] background.grain slider 0.646000
      settings.backgroundNoise=0.640000
    [Background] background.brightness slider -0.374000
      settings.backgroundBrightness=-0.380000
    [Background] background.contrast slider 1.266000
      settings.backgroundContrast=1.260000
    [Background] background.saturation slider 1.165000
      settings.backgroundSaturation=1.150000
    [Background] background.hue slider 236.500000
      settings.backgroundHue=235.000000
    [Background] background.tint color 0.800,0.600,0.100,1.000
      settings.backgroundTintColor.blue=0.100000
      settings.backgroundTintColor.green=0.600000
      settings.backgroundTintColor.red=0.800000
      settings.backgroundTintOpacity=0.300000
    [Background] background.tintAmount slider 0.526000
      settings.backgroundTintOpacity=0.520000
    [Background] background.vignette slider 0.486000
      settings.backgroundVignette=0.480000
    [Background] background.resetLook tap
      settings.backgroundBlur=0.000000
      settings.backgroundBrightness=0.000000
      settings.backgroundContrast=1.000000
      settings.backgroundHalftone=0.000000
      settings.backgroundHue=0.000000
      settings.backgroundNoise=0.000000
      settings.backgroundPixelate=0.000000
      settings.backgroundSaturation=1.000000
      settings.backgroundTintOpacity=0.000000
      settings.backgroundVignette=0.000000
      visible: background.angle,background.blur,background.brightness,background.contrast,background.corners,background.deviceFrame,background.gradientEnd,background.gradientStart,background.grain,background.halftone,background.hue,background.menuBar,background.menuBarCaption,background.padding,background.pixelate,background.placement,background.placementReset,background.saturation,background.shadow,background.shadowOpacity,background.shape,background.tint,background.tintAmount,background.type,background.vignette
    [Background] background.type choose 1
      settings.backgroundType="Mesh"
      visible: background.blur,background.brightness,background.contrast,background.corners,background.deviceFrame,background.gradientEnd,background.gradientStart,background.grain,background.halftone,background.hue,background.menuBar,background.menuBarCaption,background.padding,background.pixelate,background.placement,background.placementReset,background.saturation,background.shadow,background.shadowOpacity,background.shape,background.tint,background.tintAmount,background.type,background.vignette
    [Background] background.type choose 5
      settings.backgroundType="Transparent"
      visible: background.corners,background.deviceFrame,background.menuBar,background.menuBarCaption,background.padding,background.placement,background.placementReset,background.shadow,background.shadowOpacity,background.shape,background.transparentCaption,background.type
    [Background] background.type choose 0
      settings.backgroundType="Gradient"
      visible: background.angle,background.blur,background.brightness,background.contrast,background.corners,background.deviceFrame,background.gradientEnd,background.gradientStart,background.grain,background.halftone,background.hue,background.menuBar,background.menuBarCaption,background.padding,background.pixelate,background.placement,background.placementReset,background.saturation,background.shadow,background.shadowOpacity,background.shape,background.tint,background.tintAmount,background.type,background.vignette
    [Background] background.deviceFrame toggle
      settings.showDeviceFrame=false
    [Background] background.placementReset tap
      settings.videoCustomX=<removed>
      settings.videoCustomY=<removed>
      visible: background.angle,background.blur,background.brightness,background.contrast,background.corners,background.deviceFrame,background.gradientEnd,background.gradientStart,background.grain,background.halftone,background.hue,background.menuBar,background.menuBarCaption,background.padding,background.pixelate,background.placement,background.saturation,background.shadow,background.shadowOpacity,background.shape,background.tint,background.tintAmount,background.type,background.vignette
    [Background] background.placement choose 3
      settings.videoPlacement="Top Right"
    [Background] background.placementPad pad 0.100,0.900
      settings.videoPlacement="Bottom Left"
    [Background] background.placementPad pad 0.500,0.200
      settings.videoPlacement="Top"
    [Background] background.padding slider 121.200000
      settings.backgroundPadding=120.000000
    [Background] background.shape choose 1
      settings.frameShape="Squircle"
    [Background] background.corners slider 11.300000
      settings.cornerRadius=11.000000
      settings.windowCornerRadius=11.000000
    [Background] background.shadow slider 18.600000
      settings.shadowRadius=18.000000
    [Background] background.shadowOpacity slider 0.715000
      settings.shadowOpacity=0.700000
    [Background] background.menuBar choose 2
      settings.menuBarReplacement="Clean Dark"
      visible: background.angle,background.blur,background.brightness,background.contrast,background.corners,background.deviceFrame,background.gradientEnd,background.gradientStart,background.grain,background.halftone,background.hue,background.menuBar,background.menuBarAlign,background.menuBarCaption,background.menuBarClock,background.menuBarHeight,background.menuBarIcons,background.menuBarTitle,background.padding,background.pixelate,background.placement,background.saturation,background.shadow,background.shadowOpacity,background.shape,background.tint,background.tintAmount,background.type,background.vignette
    [Background] background.menuBarTitle text "Studio Demo"
      settings.menuBarTitle="Studio Demo"
    [Background] background.menuBarAlign choose 2
      settings.menuBarTitleAlignment="Right"
    [Background] background.menuBarClock text "10:09"
      settings.menuBarClock="10:09"
    [Background] background.menuBarIcons toggle
      settings.menuBarShowStatusIcons=false
    [Background] background.menuBarHeight slider 4.430000
      settings.menuBarHeight=4.400000
    [Background] background.menuBar choose 1
      settings.menuBarReplacement="Hidden"
      visible: background.angle,background.blur,background.brightness,background.contrast,background.corners,background.deviceFrame,background.gradientEnd,background.gradientStart,background.grain,background.halftone,background.hue,background.menuBar,background.menuBarCaption,background.menuBarHeight,background.padding,background.pixelate,background.placement,background.saturation,background.shadow,background.shadowOpacity,background.shape,background.tint,background.tintAmount,background.type,background.vignette
    [Background] background.menuBar choose 0
      settings.menuBarReplacement="Original"
      visible: background.angle,background.blur,background.brightness,background.contrast,background.corners,background.deviceFrame,background.gradientEnd,background.gradientStart,background.grain,background.halftone,background.hue,background.menuBar,background.menuBarCaption,background.padding,background.pixelate,background.placement,background.saturation,background.shadow,background.shadowOpacity,background.shape,background.tint,background.tintAmount,background.type,background.vignette
    [Cursor] cursor.show toggle
      settings.showCursor=false
      selection: zoom=- tilt=- highlight=- depth=- blur=- annotation=- tab=Cursor
      visible: cursor.autoHide,cursor.clickSound,cursor.endCaption,cursor.fluid,cursor.friction,cursor.frictionCaption,cursor.keySound,cursor.keystrokeAnimation,cursor.keystrokeCaption,cursor.keystrokeOverlay,cursor.keystrokePosition,cursor.keystrokeScope,cursor.keystrokeScopeCaption,cursor.keystrokeSize,cursor.loop,cursor.mass,cursor.massCaption,cursor.ripple,cursor.rippleColor,cursor.rippleSize,cursor.show,cursor.size,cursor.smooth,cursor.stopEnd,cursor.style,cursor.tension,cursor.tensionCaption
    [Cursor] cursor.show toggle
      settings.showCursor=true
    [Cursor] cursor.style choose 3
      settings.cursorStyle="Dot"
    [Cursor] cursor.size slider 2.575000
      settings.cursorScale=2.500000
    [Cursor] cursor.tension slider 363.000000
      settings.cursorTension=360.000000
    [Cursor] cursor.friction slider 48.300000
      settings.cursorFriction=48.000000
    [Cursor] cursor.mass slider 1.730000
      settings.cursorMass=1.700000
    [Cursor] cursor.fluid toggle
      settings.cursorFluidEnabled=false
      visible: cursor.autoHide,cursor.clickSound,cursor.endCaption,cursor.fluid,cursor.keySound,cursor.keystrokeAnimation,cursor.keystrokeCaption,cursor.keystrokeOverlay,cursor.keystrokePosition,cursor.keystrokeScope,cursor.keystrokeScopeCaption,cursor.keystrokeSize,cursor.loop,cursor.ripple,cursor.rippleColor,cursor.rippleSize,cursor.show,cursor.size,cursor.smooth,cursor.stopEnd,cursor.style
    [Cursor] cursor.fluid toggle
      settings.cursorFluidEnabled=true
      visible: cursor.autoHide,cursor.clickSound,cursor.endCaption,cursor.fluid,cursor.friction,cursor.frictionCaption,cursor.keySound,cursor.keystrokeAnimation,cursor.keystrokeCaption,cursor.keystrokeOverlay,cursor.keystrokePosition,cursor.keystrokeScope,cursor.keystrokeScopeCaption,cursor.keystrokeSize,cursor.loop,cursor.mass,cursor.massCaption,cursor.ripple,cursor.rippleColor,cursor.rippleSize,cursor.show,cursor.size,cursor.smooth,cursor.stopEnd,cursor.style,cursor.tension,cursor.tensionCaption
    [Cursor] cursor.smooth toggle
      settings.smoothCursor=true
      visible: cursor.autoHide,cursor.clickSound,cursor.endCaption,cursor.fluid,cursor.friction,cursor.frictionCaption,cursor.keySound,cursor.keystrokeAnimation,cursor.keystrokeCaption,cursor.keystrokeOverlay,cursor.keystrokePosition,cursor.keystrokeScope,cursor.keystrokeScopeCaption,cursor.keystrokeSize,cursor.loop,cursor.mass,cursor.massCaption,cursor.ripple,cursor.rippleColor,cursor.rippleSize,cursor.show,cursor.size,cursor.smooth,cursor.smoothing,cursor.stopEnd,cursor.style,cursor.tension,cursor.tensionCaption
    [Cursor] cursor.smoothing slider 0.365000
      settings.smoothingFactor=0.350000
    [Cursor] cursor.autoHide toggle
      settings.autoHideCursor=true
      visible: cursor.autoHide,cursor.clickSound,cursor.endCaption,cursor.fluid,cursor.friction,cursor.frictionCaption,cursor.hideAfter,cursor.keySound,cursor.keystrokeAnimation,cursor.keystrokeCaption,cursor.keystrokeOverlay,cursor.keystrokePosition,cursor.keystrokeScope,cursor.keystrokeScopeCaption,cursor.keystrokeSize,cursor.loop,cursor.mass,cursor.massCaption,cursor.ripple,cursor.rippleColor,cursor.rippleSize,cursor.show,cursor.size,cursor.smooth,cursor.smoothing,cursor.stopEnd,cursor.style,cursor.tension,cursor.tensionCaption
    [Cursor] cursor.hideAfter slider 5.150000
      settings.autoHideDelay=5.000000
    [Cursor] cursor.loop toggle
      settings.cursorLoopToStart=true
    [Cursor] cursor.stopEnd toggle
      settings.cursorLoopToStart=false
      settings.cursorStopAtEnd=true
    [Cursor] cursor.stopEnd toggle
      settings.cursorStopAtEnd=false
    [Cursor] cursor.rippleSize slider 61.500000
      settings.clickRippleSize=60.000000
    [Cursor] cursor.rippleColor color 0.300,0.900,0.400,1.000
      settings.clickRippleColor.blue=0.400000
      settings.clickRippleColor.green=0.900000
      settings.clickRippleColor.red=0.300000
    [Cursor] cursor.ripple toggle
      settings.showClickRipple=false
      visible: cursor.autoHide,cursor.clickSound,cursor.endCaption,cursor.fluid,cursor.friction,cursor.frictionCaption,cursor.hideAfter,cursor.keySound,cursor.keystrokeAnimation,cursor.keystrokeCaption,cursor.keystrokeOverlay,cursor.keystrokePosition,cursor.keystrokeScope,cursor.keystrokeScopeCaption,cursor.keystrokeSize,cursor.loop,cursor.mass,cursor.massCaption,cursor.ripple,cursor.show,cursor.size,cursor.smooth,cursor.smoothing,cursor.stopEnd,cursor.style,cursor.tension,cursor.tensionCaption
    [Cursor] cursor.ripple toggle
      settings.showClickRipple=true
      visible: cursor.autoHide,cursor.clickSound,cursor.endCaption,cursor.fluid,cursor.friction,cursor.frictionCaption,cursor.hideAfter,cursor.keySound,cursor.keystrokeAnimation,cursor.keystrokeCaption,cursor.keystrokeOverlay,cursor.keystrokePosition,cursor.keystrokeScope,cursor.keystrokeScopeCaption,cursor.keystrokeSize,cursor.loop,cursor.mass,cursor.massCaption,cursor.ripple,cursor.rippleColor,cursor.rippleSize,cursor.show,cursor.size,cursor.smooth,cursor.smoothing,cursor.stopEnd,cursor.style,cursor.tension,cursor.tensionCaption
    [Cursor] cursor.clickSound toggle
      settings.clickSoundEnabled=true
      visible: cursor.autoHide,cursor.clickCaption,cursor.clickSound,cursor.clickStyle,cursor.clickTest,cursor.clickVolume,cursor.endCaption,cursor.fluid,cursor.friction,cursor.frictionCaption,cursor.hideAfter,cursor.keySound,cursor.keystrokeAnimation,cursor.keystrokeCaption,cursor.keystrokeOverlay,cursor.keystrokePosition,cursor.keystrokeScope,cursor.keystrokeScopeCaption,cursor.keystrokeSize,cursor.loop,cursor.mass,cursor.massCaption,cursor.ripple,cursor.rippleColor,cursor.rippleSize,cursor.show,cursor.size,cursor.smooth,cursor.smoothing,cursor.stopEnd,cursor.style,cursor.tension,cursor.tensionCaption
    [Cursor] cursor.clickStyle choose 2
      settings.clickSoundStyle="Deep"
    [Cursor] cursor.clickTest tap
    [Cursor] cursor.clickVolume slider 0.615000
      settings.clickSoundVolume=0.600000
    [Cursor] cursor.keySound toggle
      settings.keySoundEnabled=true
      visible: cursor.autoHide,cursor.clickCaption,cursor.clickSound,cursor.clickStyle,cursor.clickTest,cursor.clickVolume,cursor.endCaption,cursor.fluid,cursor.friction,cursor.frictionCaption,cursor.hideAfter,cursor.keyCaption,cursor.keySound,cursor.keyStyle,cursor.keyTest,cursor.keyVolume,cursor.keystrokeAnimation,cursor.keystrokeCaption,cursor.keystrokeOverlay,cursor.keystrokePosition,cursor.keystrokeScope,cursor.keystrokeScopeCaption,cursor.keystrokeSize,cursor.loop,cursor.mass,cursor.massCaption,cursor.ripple,cursor.rippleColor,cursor.rippleSize,cursor.show,cursor.size,cursor.smooth,cursor.smoothing,cursor.stopEnd,cursor.style,cursor.tension,cursor.tensionCaption
    [Cursor] cursor.keyStyle choose 3
      settings.keySoundStyle="Cream"
    [Cursor] cursor.keyTest tap
    [Cursor] cursor.keyVolume slider 0.465000
      settings.keySoundVolume=0.450000
    [Cursor] cursor.keystrokePosition choose 2
      settings.keystrokeOverlayPosition="bottomRight"
    [Cursor] cursor.keystrokeAnimation choose 1
      settings.keystrokeOverlayAnimation="fade"
    [Cursor] cursor.keystrokeSize slider 1.130000
      settings.keystrokeOverlaySize=1.100000
    [Cursor] cursor.keystrokeScope toggle
      settings.keystrokeOverlayScopeToRecordedApp=false
    [Cursor] cursor.keystrokeOverlay toggle
      settings.showKeystrokes=false
      visible: cursor.autoHide,cursor.clickCaption,cursor.clickSound,cursor.clickStyle,cursor.clickTest,cursor.clickVolume,cursor.endCaption,cursor.fluid,cursor.friction,cursor.frictionCaption,cursor.hideAfter,cursor.keyCaption,cursor.keySound,cursor.keyStyle,cursor.keyTest,cursor.keyVolume,cursor.keystrokeOverlay,cursor.loop,cursor.mass,cursor.massCaption,cursor.ripple,cursor.rippleColor,cursor.rippleSize,cursor.show,cursor.size,cursor.smooth,cursor.smoothing,cursor.stopEnd,cursor.style,cursor.tension,cursor.tensionCaption
    [Cursor] cursor.keystrokeOverlay toggle
      settings.showKeystrokes=true
      visible: cursor.autoHide,cursor.clickCaption,cursor.clickSound,cursor.clickStyle,cursor.clickTest,cursor.clickVolume,cursor.endCaption,cursor.fluid,cursor.friction,cursor.frictionCaption,cursor.hideAfter,cursor.keyCaption,cursor.keySound,cursor.keyStyle,cursor.keyTest,cursor.keyVolume,cursor.keystrokeAnimation,cursor.keystrokeCaption,cursor.keystrokeOverlay,cursor.keystrokePosition,cursor.keystrokeScope,cursor.keystrokeScopeCaption,cursor.keystrokeSize,cursor.loop,cursor.mass,cursor.massCaption,cursor.ripple,cursor.rippleColor,cursor.rippleSize,cursor.show,cursor.size,cursor.smooth,cursor.smoothing,cursor.stopEnd,cursor.style,cursor.tension,cursor.tensionCaption
    [Camera] camera.mirror toggle
      settings.cameraMirrored=true
      selection: zoom=- tilt=- highlight=- depth=- blur=- annotation=- tab=Camera
      visible: camera.background,camera.borderColor,camera.borderColorReset,camera.borderWidth,camera.brightness,camera.contrast,camera.filter,camera.hue,camera.mirror,camera.opacity,camera.position,camera.ringLight,camera.saturation,camera.shape,camera.show,camera.shrink,camera.size,camera.stack,camera.tagFill,camera.tagPosition,camera.tagSubtext,camera.tagText,camera.tagTextColor
    [Camera] camera.position choose 1
      settings.cameraPosition="Top Right"
    [Camera] camera.pad pad 0.420,0.610
      settings.cameraCustomX=0.420000
      settings.cameraCustomY=0.610000
    [Camera] camera.pad pad 0.970,0.030
      settings.cameraCustomX=<removed>
      settings.cameraCustomY=<removed>
    [Camera] camera.shape choose 2
      settings.cameraShape="Rounded Rectangle"
      visible: camera.background,camera.borderColor,camera.borderColorReset,camera.borderWidth,camera.brightness,camera.contrast,camera.cornerRadius,camera.filter,camera.hue,camera.mirror,camera.opacity,camera.orientation,camera.position,camera.ringLight,camera.saturation,camera.shape,camera.show,camera.shrink,camera.size,camera.stack,camera.tagFill,camera.tagPosition,camera.tagSubtext,camera.tagText,camera.tagTextColor
    [Camera] camera.orientation choose 2
      settings.cameraOrientation="Wide"
    [Camera] camera.size slider 16.650000
      settings.cameraSize=240.240000
    [Camera] camera.shrink toggle
      settings.cameraShrinkOnZoom=false
    [Camera] camera.stack toggle
      settings.cameraPortraitStack=true
      visible: camera.background,camera.borderColor,camera.borderColorReset,camera.borderWidth,camera.brightness,camera.contrast,camera.cornerRadius,camera.filter,camera.hue,camera.mirror,camera.opacity,camera.orientation,camera.position,camera.ringLight,camera.saturation,camera.shape,camera.show,camera.shrink,camera.size,camera.stack,camera.stackGap,camera.stackHeight,camera.tagFill,camera.tagPosition,camera.tagSubtext,camera.tagText,camera.tagTextColor
    [Camera] camera.stackHeight slider 47.300000
      settings.cameraStackRatio=0.470000
    [Camera] camera.stackGap slider 4.300000
      settings.cameraStackGap=0.040000
    [Camera] camera.background choose 2
      settings.cameraLook="popOut"
      visible: camera.background,camera.borderColor,camera.borderColorReset,camera.borderWidth,camera.brightness,camera.cardBorder,camera.cardFill,camera.cardGradientEnd,camera.cardGradientStart,camera.contrast,camera.cornerRadius,camera.edgeInset,camera.edgeSoftness,camera.filter,camera.hue,camera.mirror,camera.opacity,camera.orientation,camera.popOut,camera.position,camera.ringLight,camera.saturation,camera.shape,camera.show,camera.shrink,camera.size,camera.stack,camera.stackGap,camera.stackHeight,camera.tagFill,camera.tagPosition,camera.tagSubtext,camera.tagText,camera.tagTextColor
    [Camera] camera.edgeSoftness slider 0.315000
      settings.cameraEdgeSoftness=0.300000
    [Camera] camera.edgeInset slider 0.215000
      settings.cameraEdgeInset=0.200000
    [Camera] camera.popOut slider 0.715000
      settings.cameraPopOutAmount=0.700000
    [Camera] camera.cardFill choose 0
    [Camera] camera.cardGradientStart color 0.950,0.500,0.200,1.000
      settings.cameraCardGradientStart.blue=0.200000
      settings.cameraCardGradientStart.green=0.500000
      settings.cameraCardGradientStart.opacity=1.000000
      settings.cameraCardGradientStart.red=0.950000
    [Camera] camera.cardGradientEnd color 0.200,0.300,0.700,1.000
      settings.cameraCardGradientEnd.blue=0.700000
      settings.cameraCardGradientEnd.green=0.300000
      settings.cameraCardGradientEnd.opacity=1.000000
      settings.cameraCardGradientEnd.red=0.200000
    [Camera] camera.cardFill choose 2
      settings.cameraCardFill="color"
      visible: camera.background,camera.borderColor,camera.borderColorReset,camera.borderWidth,camera.brightness,camera.cardBorder,camera.cardColor,camera.cardFill,camera.contrast,camera.cornerRadius,camera.edgeInset,camera.edgeSoftness,camera.filter,camera.hue,camera.mirror,camera.opacity,camera.orientation,camera.popOut,camera.position,camera.ringLight,camera.saturation,camera.shape,camera.show,camera.shrink,camera.size,camera.stack,camera.stackGap,camera.stackHeight,camera.tagFill,camera.tagPosition,camera.tagSubtext,camera.tagText,camera.tagTextColor
    [Camera] camera.cardColor color 0.100,0.600,0.500,1.000
      settings.cameraCardColor.blue=0.500000
      settings.cameraCardColor.green=0.600000
      settings.cameraCardColor.opacity=1.000000
      settings.cameraCardColor.red=0.100000
    [Camera] camera.cardFill choose 1
      settings.cameraCardFill="camera"
      visible: camera.background,camera.backgroundBlur,camera.borderColor,camera.borderColorReset,camera.borderWidth,camera.brightness,camera.cardBorder,camera.cardFill,camera.contrast,camera.cornerRadius,camera.edgeInset,camera.edgeSoftness,camera.filter,camera.hue,camera.mirror,camera.opacity,camera.orientation,camera.popOut,camera.position,camera.ringLight,camera.saturation,camera.shape,camera.show,camera.shrink,camera.size,camera.stack,camera.stackGap,camera.stackHeight,camera.tagFill,camera.tagPosition,camera.tagSubtext,camera.tagText,camera.tagTextColor
    [Camera] camera.backgroundBlur slider 0.565000
      settings.cameraBackgroundBlur=0.550000
    [Camera] camera.cardBorder choose 1
      settings.cameraCardBorder="solid"
      visible: camera.background,camera.backgroundBlur,camera.borderColor,camera.borderColorReset,camera.borderWidth,camera.brightness,camera.cardBorder,camera.cardBorderColor,camera.cardBorderWidth,camera.cardFill,camera.contrast,camera.cornerRadius,camera.edgeInset,camera.edgeSoftness,camera.filter,camera.hue,camera.mirror,camera.opacity,camera.orientation,camera.popOut,camera.position,camera.ringLight,camera.saturation,camera.shape,camera.show,camera.shrink,camera.size,camera.stack,camera.stackGap,camera.stackHeight,camera.tagFill,camera.tagPosition,camera.tagSubtext,camera.tagText,camera.tagTextColor
    [Camera] camera.cardBorderWidth slider 0.415000
      settings.cameraCardBorderWidth=0.400000
    [Camera] camera.cardBorderColor color 0.900,0.900,0.200,1.000
      settings.cameraCardBorderColor.blue=0.200000
      settings.cameraCardBorderColor.green=0.900000
      settings.cameraCardBorderColor.opacity=1.000000
      settings.cameraCardBorderColor.red=0.900000
    [Camera] camera.cardBorder choose 2
      settings.cameraCardBorder="aurora"
      visible: camera.background,camera.backgroundBlur,camera.borderColor,camera.borderColorReset,camera.borderWidth,camera.brightness,camera.cardBorder,camera.cardBorderWidth,camera.cardFill,camera.contrast,camera.cornerRadius,camera.edgeInset,camera.edgeSoftness,camera.filter,camera.hue,camera.mirror,camera.opacity,camera.orientation,camera.popOut,camera.position,camera.ringLight,camera.saturation,camera.shape,camera.show,camera.shrink,camera.size,camera.stack,camera.stackGap,camera.stackHeight,camera.tagFill,camera.tagPosition,camera.tagSubtext,camera.tagText,camera.tagTextColor
    [Camera] camera.background choose 1
      settings.cameraLook="cutout"
      visible: camera.background,camera.borderColor,camera.borderColorReset,camera.borderWidth,camera.brightness,camera.contrast,camera.cornerRadius,camera.edgeInset,camera.edgeSoftness,camera.filter,camera.hue,camera.mirror,camera.opacity,camera.orientation,camera.position,camera.ringLight,camera.saturation,camera.shape,camera.show,camera.shrink,camera.size,camera.stack,camera.stackGap,camera.stackHeight,camera.tagFill,camera.tagPosition,camera.tagSubtext,camera.tagText,camera.tagTextColor
    [Camera] camera.brightness slider 0.165000
      settings.cameraBrightness=0.150000
    [Camera] camera.contrast slider 0.815000
      settings.cameraContrast=0.800000
    [Camera] camera.saturation slider 1.615000
      settings.cameraSaturation=1.600000
    [Camera] camera.hue slider -83.500000
      settings.cameraHue=-85.000000
    [Camera] camera.filter choose 3
      settings.cameraFilter="Warm"
    [Camera] camera.ringLight slider 0.465000
      settings.cameraRingLight=0.450000
    [Camera] camera.cornerRadius slider 30.300000
      settings.cameraCornerRadius=30.000000
    [Camera] camera.borderWidth slider 2.650000
      settings.cameraBorderWidth=2.500000
    [Camera] camera.borderColor color 0.700,0.200,0.900,0.600
      settings.cameraBorderColor.blue=0.900000
      settings.cameraBorderColor.green=0.200000
      settings.cameraBorderColor.opacity=0.600000
      settings.cameraBorderColor.red=0.700000
    [Camera] camera.borderColorReset tap
      settings.cameraBorderColor.blue=<removed>
      settings.cameraBorderColor.green=<removed>
      settings.cameraBorderColor.opacity=<removed>
      settings.cameraBorderColor.red=<removed>
    [Camera] camera.opacity slider 0.715000
      settings.cameraOpacity=0.700000
    [Camera] camera.tiltPad pad 0.400,-0.600
      settings.cameraTiltPitch=-15.000000
      settings.cameraTiltYaw=10.000000
    [Camera] camera.tagText text "Ada Lovelace"
      settings.cameraTagText="Ada Lovelace"
    [Camera] camera.tagSubtext text "Analyst"
      settings.cameraTagSubtext="Analyst"
    [Camera] camera.tagPosition choose 2
      settings.cameraTagPosition="Overlap Bottom"
    [Camera] camera.tagTextColor color 1.000,0.900,0.800,1.000
      settings.cameraTagTextColor.blue=0.800000
      settings.cameraTagTextColor.green=0.900000
    [Camera] camera.tagFill color 0.100,0.100,0.300,0.700
      settings.cameraTagBackgroundColor.blue=0.300000
      settings.cameraTagBackgroundColor.green=0.100000
      settings.cameraTagBackgroundColor.opacity=0.700000
      settings.cameraTagBackgroundColor.red=0.100000
    [Camera] camera.background choose 0
      settings.cameraLook=<removed>
      visible: camera.background,camera.borderColor,camera.borderColorReset,camera.borderWidth,camera.brightness,camera.contrast,camera.cornerRadius,camera.filter,camera.hue,camera.mirror,camera.opacity,camera.orientation,camera.position,camera.ringLight,camera.saturation,camera.shape,camera.show,camera.shrink,camera.size,camera.stack,camera.stackGap,camera.stackHeight,camera.tagFill,camera.tagPosition,camera.tagSubtext,camera.tagText,camera.tagTextColor
    [Camera] camera.show toggle
      settings.showCamera=false
      visible: camera.show
    [Camera] camera.show toggle
      settings.showCamera=true
      visible: camera.background,camera.borderColor,camera.borderColorReset,camera.borderWidth,camera.brightness,camera.contrast,camera.cornerRadius,camera.filter,camera.hue,camera.mirror,camera.opacity,camera.orientation,camera.position,camera.ringLight,camera.saturation,camera.shape,camera.show,camera.shrink,camera.size,camera.stack,camera.stackGap,camera.stackHeight,camera.tagFill,camera.tagPosition,camera.tagSubtext,camera.tagText,camera.tagTextColor
    [Audio] audio.system slider 0.415000
      settings.systemAudioVolume=0.400000
      selection: zoom=- tilt=- highlight=- depth=- blur=- annotation=- tab=Audio
      visible: audio.microphone,audio.system,audio.voiceOver
    [Audio] audio.microphone slider 0.015000
      settings.microphoneVolume=0.000000
    [Audio] audio.microphone slider 0.815000
      settings.microphoneVolume=0.800000
    [Audio] audio.voiceOver slider 1.365000
      settings.voiceOverVolume=1.350000
    [Motion] motion.speed choose 3
      settings.animationSpeed="Rapid"
      selection: zoom=- tilt=- highlight=- depth=- blur=- annotation=- tab=Motion
      visible: motion.follow,motion.followCaption,motion.speed,motion.speedCaption,motion.zoomCaption,motion.zoomLevel
    [Motion] motion.zoomLevel slider 2.730000
      settings.autoZoomLevel=2.700000
    [Motion] motion.follow slider 0.265000
      settings.cameraFollowSpeed=0.250000
    [Effects] effects.slide toggle
      settings.introSlideStyle="Bottom"
      selection: zoom=- tilt=- highlight=- depth=- blur=- annotation=- tab=Effects
      visible: blocks.tilt,blocks.zoom,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideBounce,effects.slideCaption,effects.slideDepth,effects.slideSpeed,effects.slideStyle
    [Effects] effects.slideStyle choose 2
      settings.introSlideStyle="Left"
    [Effects] effects.slideBounce slider 0.565000
      settings.introSlideBounce=0.550000
    [Effects] effects.slideSpeed slider 2.075000
      settings.introSlideSpeed=2.000000
    [Effects] effects.slideDepth toggle
      settings.introSlideDepth=true
    [Effects] effects.slide toggle
      settings.introSlideStyle="Off"
      visible: blocks.tilt,blocks.zoom,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    [Effects] effects.curtain toggle
      settings.curtainUnveilCorner="Top Left"
      visible: blocks.tilt,blocks.zoom,effects.curtain,effects.curtainCaption,effects.curtainColor,effects.curtainCorner,effects.curtainLength,effects.motionBlur,effects.motionBlurCaption,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    [Effects] effects.curtainCorner choose 3
      settings.curtainUnveilCorner="Bottom Right"
    [Effects] effects.curtainLength slider 1.730000
      settings.curtainUnveilDuration=1.700000
    [Effects] effects.curtainColor color 0.300,0.100,0.400,1.000
      settings.curtainColor.blue=0.400000
      settings.curtainColor.green=0.100000
      settings.curtainColor.opacity=1.000000
      settings.curtainColor.red=0.300000
      visible: blocks.tilt,blocks.zoom,effects.curtain,effects.curtainCaption,effects.curtainColor,effects.curtainColorReset,effects.curtainCorner,effects.curtainLength,effects.motionBlur,effects.motionBlurCaption,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    [Effects] effects.curtainColorReset tap
      settings.curtainColor.blue=<removed>
      settings.curtainColor.green=<removed>
      settings.curtainColor.opacity=<removed>
      settings.curtainColor.red=<removed>
      visible: blocks.tilt,blocks.zoom,effects.curtain,effects.curtainCaption,effects.curtainColor,effects.curtainCorner,effects.curtainLength,effects.motionBlur,effects.motionBlurCaption,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    [Effects] effects.curtainLogoChoose pick logo
      settings.curtainLogoFileName="curtain-logo-XXXXXXXX.png"
      visible: blocks.tilt,blocks.zoom,effects.curtain,effects.curtainCaption,effects.curtainColor,effects.curtainCorner,effects.curtainLength,effects.curtainLogoOpacity,effects.curtainLogoSize,effects.curtainLogoTint,effects.motionBlur,effects.motionBlurCaption,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    [Effects] effects.curtainLogoOpacity slider 0.665000
      settings.curtainLogoOpacity=0.650000
    [Effects] effects.curtainLogoSize slider 0.465000
      settings.curtainLogoScale=0.450000
    [Effects] effects.curtainLogoTint toggle
      settings.curtainLogoTint.blue=1.000000
      settings.curtainLogoTint.green=1.000000
      settings.curtainLogoTint.opacity=1.000000
      settings.curtainLogoTint.red=1.000000
      visible: blocks.tilt,blocks.zoom,effects.curtain,effects.curtainCaption,effects.curtainColor,effects.curtainCorner,effects.curtainLength,effects.curtainLogoOpacity,effects.curtainLogoSize,effects.curtainLogoTint,effects.curtainLogoTintColor,effects.motionBlur,effects.motionBlurCaption,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    [Effects] effects.curtainLogoTintColor color 0.900,0.300,0.300,1.000
      settings.curtainLogoTint.blue=0.300000
      settings.curtainLogoTint.green=0.300000
      settings.curtainLogoTint.red=0.900000
    [Effects] effects.curtainLogoRemove tap
      settings.curtainLogoFileName=<removed>
      visible: blocks.tilt,blocks.zoom,effects.curtain,effects.curtainCaption,effects.curtainColor,effects.curtainCorner,effects.curtainLength,effects.motionBlur,effects.motionBlurCaption,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    [Effects] effects.curtain toggle
      settings.curtainUnveilCorner="Off"
      visible: blocks.tilt,blocks.zoom,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    [Effects] effects.parallax toggle
      settings.parallaxStrength=0.400000
      visible: blocks.tilt,blocks.zoom,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.parallax,effects.parallaxCaption,effects.parallaxStrength,effects.slide,effects.slideCaption
    [Effects] effects.parallaxStrength slider 0.565000
      settings.parallaxStrength=0.550000
    [Effects] effects.parallax toggle
      settings.parallaxStrength=0.000000
      visible: blocks.tilt,blocks.zoom,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    [Effects] effects.motionBlur toggle
      settings.motionBlur=true
      visible: blocks.tilt,blocks.zoom,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.motionBlurStrength,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    [Effects] effects.motionBlurStrength slider 0.665000
      settings.motionBlurStrength=0.650000
    [Effects] blocks.zoom toggle
      zoom.count=2
      zoom[1].endTime=8.000000
      zoom[1].focalPoint.count=2
      zoom[1].focalPoint[0]=0.500000
      zoom[1].focalPoint[1]=0.500000
      zoom[1].id="new"
      zoom[1].startTime=5.000000
      zoom[1].zoomLevel=2.000000
      selection: zoom=new tilt=- highlight=- depth=- blur=- annotation=- tab=Effects
      visible: blocks.followCursor,blocks.tilt,blocks.zoom,blocks.zoomCaption,blocks.zoomLevel,blocks.zoomSpeed,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.motionBlurStrength,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    select zoom(1)
      selection: zoom=Z1 tilt=- highlight=- depth=- blur=- annotation=- tab=Effects
    [Effects] blocks.zoomLevel slider 2.430000
      zoom[0].zoomLevel=2.400000
    [Effects] blocks.zoomSpeed choose 4
      zoom[0].animationStyle="Slow Glide"
    [Effects] blocks.followCursor toggle
      zoom[0].followsCursor=false
    [Effects] blocks.focusPad pad 0.620,0.280
      zoom[0].focalPoint[0]=0.620000
      zoom[0].focalPoint[1]=0.280000
    [Effects] blocks.offsetPad pad 0.800,0.350
      zoom[0].cardOffsetX=0.900000
      zoom[0].cardOffsetY=-0.450000
    [Effects] blocks.offsetPad pad 0.505,0.495
      zoom[0].cardOffsetX=<removed>
      zoom[0].cardOffsetY=<removed>
    [Effects] blocks.tilt toggle
      tilt.count=2
      tilt[1].endTime=5.000000
      tilt[1].id="new"
      tilt[1].pitch=20.000000
      tilt[1].roll=0.000000
      tilt[1].startTime=2.000000
      tilt[1].yaw=0.000000
      selection: zoom=Z1 tilt=new highlight=- depth=- blur=- annotation=- tab=Effects
      visible: blocks.cinematic,blocks.followCursor,blocks.rotation,blocks.tilt,blocks.tiltCaption,blocks.tiltPreset,blocks.tiltSpeed,blocks.zoom,blocks.zoomCaption,blocks.zoomLevel,blocks.zoomSpeed,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.motionBlurStrength,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    [Effects] blocks.tiltPad pad -0.350,0.500
      tilt[1].pitch=30.000000
      tilt[1].yaw=-21.000000
    [Effects] blocks.tiltPreset choose 2
      tilt[1].pitch=8.000000
      tilt[1].roll=-2.000000
      tilt[1].yaw=-25.000000
    [Effects] blocks.rotation slider -17.700000
      tilt[1].roll=-18.000000
    [Effects] blocks.tiltSpeed choose 2
      tilt[1].animationStyle="Snappy"
    [Effects] blocks.cinematic tap
      tilt[1].pitch=12.000000
      tilt[1].roll=-3.000000
      tilt[1].yaw=0.000000
    [Effects] effects.slide toggle
      settings.introSlideDuration=3.000000
      settings.introSlideStart=2.000000
      settings.introSlideStyle="Bottom"
      visible: blocks.cinematic,blocks.followCursor,blocks.rotation,blocks.tilt,blocks.tiltCaption,blocks.tiltPreset,blocks.tiltSpeed,blocks.zoom,blocks.zoomCaption,blocks.zoomLevel,blocks.zoomSpeed,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.motionBlurStrength,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideBounce,effects.slideCaption,effects.slideDepth,effects.slideSpeed,effects.slideStyle
    [Effects] effects.slide toggle
      settings.introSlideStyle="Off"
      visible: blocks.cinematic,blocks.followCursor,blocks.rotation,blocks.tilt,blocks.tiltCaption,blocks.tiltPreset,blocks.tiltSpeed,blocks.zoom,blocks.zoomCaption,blocks.zoomLevel,blocks.zoomSpeed,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.motionBlurStrength,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    [Effects] blocks.tilt toggle
      tilt.count=1
      tilt[1].animationStyle=<removed>
      tilt[1].endTime=<removed>
      tilt[1].id=<removed>
      tilt[1].pitch=<removed>
      tilt[1].roll=<removed>
      tilt[1].startTime=<removed>
      tilt[1].yaw=<removed>
      selection: zoom=Z1 tilt=- highlight=- depth=- blur=- annotation=- tab=Effects
      visible: blocks.followCursor,blocks.tilt,blocks.zoom,blocks.zoomCaption,blocks.zoomLevel,blocks.zoomSpeed,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.motionBlurStrength,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    [Effects] blocks.zoom toggle
      zoom.count=1
      zoom[0].animationStyle=<removed>
      zoom[0].endTime=8.000000
      zoom[0].focalPoint[0]=0.500000
      zoom[0].focalPoint[1]=0.500000
      zoom[0].followsCursor=<removed>
      zoom[0].id="new"
      zoom[0].startTime=5.000000
      zoom[0].zoomLevel=2.000000
      zoom[1].endTime=<removed>
      zoom[1].focalPoint.count=<removed>
      zoom[1].focalPoint[0]=<removed>
      zoom[1].focalPoint[1]=<removed>
      zoom[1].id=<removed>
      zoom[1].startTime=<removed>
      zoom[1].zoomLevel=<removed>
      selection: zoom=- tilt=- highlight=- depth=- blur=- annotation=- tab=Effects
      visible: blocks.tilt,blocks.zoom,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.motionBlurStrength,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    select tilt(2)
      selection: zoom=- tilt=T2 highlight=- depth=- blur=- annotation=- tab=Effects
      visible: blocks.cinematic,blocks.rotation,blocks.tilt,blocks.tiltCaption,blocks.tiltPreset,blocks.tiltSpeed,blocks.zoom,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.motionBlurStrength,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    [Effects] blocks.zoom toggle
      zoom.count=2
      zoom[1].endTime=10.000000
      zoom[1].focalPoint.count=2
      zoom[1].focalPoint[0]=0.500000
      zoom[1].focalPoint[1]=0.500000
      zoom[1].id="new"
      zoom[1].startTime=8.000000
      zoom[1].zoomLevel=2.700000
      selection: zoom=new tilt=T2 highlight=- depth=- blur=- annotation=- tab=Effects
      visible: blocks.cinematic,blocks.followCursor,blocks.rotation,blocks.tilt,blocks.tiltCaption,blocks.tiltPreset,blocks.tiltSpeed,blocks.zoom,blocks.zoomCaption,blocks.zoomLevel,blocks.zoomSpeed,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.motionBlurStrength,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    [Effects] blocks.cinematic tap
      tilt[0].roll=-3.000000
      tilt[0].yaw=0.000000
      zoom[1].zoomLevel=2.400000
    select highlight(3)
      selection: zoom=- tilt=- highlight=H3 depth=- blur=- annotation=- tab=Effects
      visible: blocks.highlightCaption,blocks.highlightOpacity,blocks.removeHighlight,blocks.tilt,blocks.zoom,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.motionBlurStrength,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    [Effects] blocks.highlightOpacity slider 0.580000
      highlight[0].opacity=0.580000
    [Effects] blocks.removeHighlight tap
      highlight.count=0
      highlight[0].endTime=<removed>
      highlight[0].id=<removed>
      highlight[0].label=<removed>
      highlight[0].opacity=<removed>
      highlight[0].rectH=<removed>
      highlight[0].rectW=<removed>
      highlight[0].rectX=<removed>
      highlight[0].rectY=<removed>
      highlight[0].startTime=<removed>
      selection: zoom=- tilt=- highlight=- depth=- blur=- annotation=- tab=Effects
      visible: blocks.tilt,blocks.zoom,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.motionBlurStrength,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    select depth(4)
      selection: zoom=- tilt=- highlight=- depth=F4 blur=- annotation=- tab=Effects
      visible: blocks.depthCaption,blocks.depthCorner,blocks.depthFalloff,blocks.depthStrength,blocks.depthStyle,blocks.removeDepth,blocks.tilt,blocks.zoom,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.motionBlurStrength,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    [Effects] blocks.depthStrength slider 0.465000
      depth[0].intensity=0.450000
    [Effects] blocks.depthFalloff slider 0.665000
      depth[0].falloff=0.650000
    [Effects] blocks.depthCorner slider 0.265000
      depth[0].cornerRadius=0.250000
    [Effects] blocks.depthStyle choose 1
      depth[0].style="Tilt Shift"
      visible: blocks.depthAngle,blocks.depthCaption,blocks.depthFalloff,blocks.depthStrength,blocks.depthStyle,blocks.removeDepth,blocks.tilt,blocks.zoom,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.motionBlurStrength,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    [Effects] blocks.depthAngle slider -35.700000
      depth[0].angle=-36.000000
    [Effects] blocks.removeDepth tap
      depth.count=0
      depth[0].angle=<removed>
      depth[0].cornerRadius=<removed>
      depth[0].endTime=<removed>
      depth[0].falloff=<removed>
      depth[0].id=<removed>
      depth[0].intensity=<removed>
      depth[0].label=<removed>
      depth[0].rectH=<removed>
      depth[0].rectW=<removed>
      depth[0].rectX=<removed>
      depth[0].rectY=<removed>
      depth[0].startTime=<removed>
      depth[0].style=<removed>
      selection: zoom=- tilt=- highlight=- depth=- blur=- annotation=- tab=Effects
      visible: blocks.tilt,blocks.zoom,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.motionBlurStrength,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    select blur(5)
      selection: zoom=- tilt=- highlight=- depth=- blur=B5 annotation=- tab=Effects
      visible: blocks.blurCaption,blocks.blurStrength,blocks.blurStyle,blocks.removeBlur,blocks.tilt,blocks.zoom,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.motionBlurStrength,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    [Effects] blocks.blurStyle choose 1
      blur[0].style="Pixelate"
      visible: blocks.blurAnimated,blocks.blurCaption,blocks.blurStrength,blocks.blurStyle,blocks.removeBlur,blocks.tilt,blocks.zoom,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.motionBlurStrength,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    [Effects] blocks.blurStrength slider 0.815000
      blur[0].intensity=0.800000
    [Effects] blocks.blurAnimated toggle
      blur[0].animated=true
    [Effects] blocks.removeBlur tap
      blur.count=0
      blur[0].animated=<removed>
      blur[0].endTime=<removed>
      blur[0].id=<removed>
      blur[0].intensity=<removed>
      blur[0].label=<removed>
      blur[0].rectH=<removed>
      blur[0].rectW=<removed>
      blur[0].rectX=<removed>
      blur[0].rectY=<removed>
      blur[0].startTime=<removed>
      blur[0].style=<removed>
      selection: zoom=- tilt=- highlight=- depth=- blur=- annotation=- tab=Effects
      visible: blocks.tilt,blocks.zoom,effects.curtain,effects.curtainCaption,effects.motionBlur,effects.motionBlurCaption,effects.motionBlurStrength,effects.parallax,effects.parallaxCaption,effects.slide,effects.slideCaption
    select none
      selection: zoom=- tilt=- highlight=- depth=- blur=- annotation=- tab=Effects
    [Subtitles] subtitles.presets preset 3
      settings.highlightWords=true
      selection: zoom=- tilt=- highlight=- depth=- blur=- annotation=- tab=Subtitles
      visible: subtitles.color,subtitles.font,subtitles.highlight,subtitles.karaoke,subtitles.position,subtitles.show,subtitles.size,subtitles.style,subtitles.uppercase,subtitles.weight
    [Subtitles] subtitles.size slider 36.600000
      settings.subtitleFontSize=36.000000
    [Subtitles] subtitles.font choose 2
      settings.subtitleFontName="Avenir Next"
    [Subtitles] subtitles.weight choose 4
      settings.subtitleWeight="Heavy"
    [Subtitles] subtitles.uppercase toggle
      settings.subtitleUppercase=true
    [Subtitles] subtitles.color color 0.900,0.950,0.600,1.000
      settings.subtitleColor.blue=0.600000
      settings.subtitleColor.green=0.950000
      settings.subtitleColor.red=0.900000
    [Subtitles] subtitles.position choose 0
      settings.subtitlePosition="Top"
    [Subtitles] subtitles.positionPad pad 0.200,0.700
      settings.subtitleCustomX=0.200000
      settings.subtitleCustomY=0.700000
    [Subtitles] subtitles.positionPad pad 0.520,0.470
      settings.subtitleCustomX=<removed>
      settings.subtitleCustomY=<removed>
      settings.subtitlePosition="Center"
    [Subtitles] subtitles.style choose 1
      settings.subtitleStyle="Background"
      visible: subtitles.background,subtitles.color,subtitles.font,subtitles.highlight,subtitles.karaoke,subtitles.position,subtitles.show,subtitles.size,subtitles.style,subtitles.uppercase,subtitles.weight
    [Subtitles] subtitles.background color 0.200,0.000,0.300,0.800
      settings.subtitleBackgroundColor.blue=0.300000
      settings.subtitleBackgroundColor.opacity=0.800000
      settings.subtitleBackgroundColor.red=0.200000
    [Subtitles] subtitles.highlight color 0.400,1.000,0.400,1.000
      settings.subtitleHighlightColor.blue=0.400000
      settings.subtitleHighlightColor.green=1.000000
      settings.subtitleHighlightColor.red=0.400000
    [Subtitles] subtitles.karaoke toggle
      settings.highlightWords=false
      visible: subtitles.background,subtitles.color,subtitles.font,subtitles.karaoke,subtitles.position,subtitles.show,subtitles.size,subtitles.style,subtitles.uppercase,subtitles.weight
    [Subtitles] subtitles.captions caption 1 "Second line, edited"
      subtitles[1].text="Second line, edited"
    [Subtitles] subtitles.presets preset 1
      settings.subtitleBackgroundColor.blue=0.000000
      settings.subtitleBackgroundColor.opacity=1.000000
      settings.subtitleBackgroundColor.red=0.000000
      settings.subtitleColor.blue=1.000000
      settings.subtitleColor.green=1.000000
      settings.subtitleColor.red=1.000000
      settings.subtitleUppercase=false
      settings.subtitleWeight="Semibold"
    [Subtitles] subtitles.delete tap
      subtitles.count=0
      subtitles[0].endTime=<removed>
      subtitles[0].id=<removed>
      subtitles[0].startTime=<removed>
      subtitles[0].text=<removed>
      subtitles[0].words.count=<removed>
      subtitles[1].endTime=<removed>
      subtitles[1].id=<removed>
      subtitles[1].startTime=<removed>
      subtitles[1].text=<removed>
      subtitles[1].words.count=<removed>
    [Subtitles] subtitles.show toggle
      settings.showSubtitles=false
      visible: subtitles.show
    [Brand] brand.show toggle
      settings.showWatermark=true
      selection: zoom=- tilt=- highlight=- depth=- blur=- annotation=- tab=Brand
      visible: brand.show
    [Brand] brand.choose pick logo
      settings.watermarkFileName="watermark-XXXXXXXX.png"
      visible: brand.opacity,brand.show,brand.size
    [Brand] brand.pad pad 0.300,0.970
      settings.watermarkX=0.300000
    [Brand] brand.pad pad 0.030,0.500
      settings.watermarkX=0.000000
      settings.watermarkY=0.500000
    [Brand] brand.size slider 153.000000
      settings.watermarkSize=150.000000
    [Brand] brand.opacity slider 0.615000
      settings.watermarkOpacity=0.600000
    [Brand] brand.remove tap
      settings.showWatermark=false
      settings.watermarkFileName=<removed>
      visible: brand.show
    select annotation(6)
      selection: zoom=- tilt=- highlight=- depth=- blur=- annotation=Text6 tab=Annotate
      visible: 
    [Annotate] annotate.text text "Tap here"
      annotations[0].text="Tap here"
      visible: annotate.blackout,annotate.buildIn,annotate.buildOut,annotate.color,annotate.corners,annotate.font,annotate.fontSize,annotate.opacity,annotate.shadow,annotate.text,annotate.textTip,annotate.timingTip,annotate.uppercase,annotate.weight
    [Annotate] annotate.fontSize slider 34.300000
      annotations[0].fontSize=34.000000
    [Annotate] annotate.font choose 3
      annotations[0].fontName="Futura"
    [Annotate] annotate.weight choose 4
      annotations[0].fontWeight="Heavy"
    [Annotate] annotate.uppercase toggle
      annotations[0].uppercase=true
    [Annotate] annotate.color color 1.000,0.800,0.200,1.000
      annotations[0].color.blue=0.200000
      annotations[0].color.green=0.800000
    [Annotate] annotate.fill toggle
      annotations[0].showBackground=false
    [Annotate] annotate.fill toggle
      annotations[0].showBackground=true
    [Annotate] annotate.fillColor color 0.200,0.200,0.600,0.900
      annotations[0].backgroundColor.blue=0.600000
      annotations[0].backgroundColor.green=0.200000
      annotations[0].backgroundColor.opacity=0.900000
      annotations[0].backgroundColor.red=0.200000
    [Annotate] annotate.corners slider 14.300000
      annotations[0].cornerRadius=14.000000
    [Annotate] annotate.opacity slider 0.615000
      annotations[0].opacity=0.600000
    [Annotate] annotate.blackout slider 0.015000
    [Annotate] annotate.blackout slider 0.465000
      annotations[0].backdropOpacity=0.450000
    [Annotate] annotate.buildIn choose 5
      annotations[0].enterEffect="Drop"
    [Annotate] annotate.buildOut choose 2
      annotations[0].exitEffect="Pop"
    [Annotate] annotate.shadow toggle
      annotations[0].showShadow=false
    [Annotate] annotate.start text "1.25"
      annotations[0].startTime=1.250000
    [Annotate] annotate.end text "1.5"
      annotations[0].endTime=1.750000
    [Annotate] annotate.end text "oops"
    [Annotate] annotate.atPlayhead tap
      annotations[0].endTime=9.500000
      annotations[0].startTime=6.500000
    select annotation(7)
      selection: zoom=- tilt=- highlight=- depth=- blur=- annotation=Rect7 tab=Annotate
      visible: annotate.blackout,annotate.border,annotate.buildIn,annotate.buildOut,annotate.color,annotate.corners,annotate.opacity,annotate.shadow,annotate.timingTip
    [Annotate] annotate.border slider 3.650000
      annotations[1].lineWidth=3.500000
    [Annotate] annotate.fill toggle
      annotations[1].showBackground=false
    select annotation(8)
      selection: zoom=- tilt=- highlight=- depth=- blur=- annotation=Draw8 tab=Annotate
      visible: annotate.blackout,annotate.border,annotate.buildIn,annotate.buildOut,annotate.color,annotate.drawingTip,annotate.opacity,annotate.shadow,annotate.timingTip
    [Annotate] annotate.border slider 15.650000
      annotations[2].lineWidth=15.500000
    [Annotate] annotate.undoStroke tap
      annotations[2].drawingStrokes.count=1
      annotations[2].drawingStrokes[1].count=<removed>
      annotations[2].drawingStrokes[1][0].x=<removed>
      annotations[2].drawingStrokes[1][0].y=<removed>
      annotations[2].drawingStrokes[1][1].x=<removed>
      annotations[2].drawingStrokes[1][1].y=<removed>
    [Annotate] annotate.clearStrokes tap
      annotations[2].drawingStrokes.count=0
      annotations[2].drawingStrokes[0].count=<removed>
      annotations[2].drawingStrokes[0][0].x=<removed>
      annotations[2].drawingStrokes[0][0].y=<removed>
      annotations[2].drawingStrokes[0][1].x=<removed>
      annotations[2].drawingStrokes[0][1].y=<removed>
    select annotation(9)
      selection: zoom=- tilt=- highlight=- depth=- blur=- annotation=Tap9 tab=Annotate
      visible: annotate.blackout,annotate.buildIn,annotate.buildOut,annotate.color,annotate.opacity,annotate.tapSize,annotate.tapTip,annotate.timingTip
    [Annotate] annotate.tapSize slider 86.500000
      annotations[3].fontSize=85.000000
    select annotation(10)
      selection: zoom=- tilt=- highlight=- depth=- blur=- annotation=Arrow10 tab=Annotate
      visible: annotate.blackout,annotate.border,annotate.buildIn,annotate.buildOut,annotate.color,annotate.opacity,annotate.shadow,annotate.timingTip
    [Annotate] annotate.delete tap
      annotations.count=4
      annotations[4].animatesIn=<removed>
      annotations[4].arrowEndX=<removed>
      annotations[4].arrowEndY=<removed>
      annotations[4].backdropOpacity=<removed>
      annotations[4].backgroundColor.blue=<removed>
      annotations[4].backgroundColor.green=<removed>
      annotations[4].backgroundColor.opacity=<removed>
      annotations[4].backgroundColor.red=<removed>
      annotations[4].color.blue=<removed>
      annotations[4].color.green=<removed>
      annotations[4].color.opacity=<removed>
      annotations[4].color.red=<removed>
      annotations[4].cornerRadius=<removed>
      annotations[4].drawingStrokes.count=<removed>
      annotations[4].endTime=<removed>
      annotations[4].enterEffect=<removed>
      annotations[4].exitEffect=<removed>
      annotations[4].fontSize=<removed>
      annotations[4].fontWeight=<removed>
      annotations[4].id=<removed>
      annotations[4].lineWidth=<removed>
      annotations[4].opacity=<removed>
      annotations[4].showBackground=<removed>
      annotations[4].showShadow=<removed>
      annotations[4].startTime=<removed>
      annotations[4].text=<removed>
      annotations[4].type=<removed>
      annotations[4].uppercase=<removed>
      annotations[4].x=<removed>
      annotations[4].y=<removed>
      selection: zoom=- tilt=- highlight=- depth=- blur=- annotation=- tab=Annotate
      visible: 
    select none
      selection: zoom=- tilt=- highlight=- depth=- blur=- annotation=- tab=Annotate
    """#
}
