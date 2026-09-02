import CoreGraphics

/// SwiftUI's own `Path(roundedRect:cornerSize:style:.continuous)` outline,
/// frozen as its exact bezier ELEMENT list.
///
/// `ContinuousRoundedRect` exists to reproduce SwiftUI's continuous corner, and
/// `RasterGoldenHarness.squircleCheck` used to prove it by building both paths
/// and diffing them. SwiftUI is gone, so the reference lives here instead —
/// verbs and control points captured verbatim off `Path(...).cgPath` on
/// macOS 26.2, at the commit that removed the last `import SwiftUI`. Rebuilding
/// a `CGPath` from this is bit-identical to the path SwiftUI produced, so the
/// check keeps its original strength: same cases, same symmetric
/// point-to-segment metric, same 0.5pt bar.
///
/// The cases cover both corner regimes — under the cap (`402x874 r=62.31`, the
/// real phone screen) and fully capped (`200x200 r=150`, `37.5x12.5 r=6.25`),
/// where a plain `CGPath(roundedRect:)` diverges most.
///
/// These numbers are NOT re-derivable. Never regenerate them from
/// `ContinuousRoundedRect` — that would make the gate assert against itself.
enum SquircleReference {
    /// Every case uses the harness's deliberately off-origin rect.
    static let rectOrigin = CGPoint(x: 13.25, y: -7.5)

    enum Element {
        case move(CGPoint)
        case line(CGPoint)
        case curve(CGPoint, CGPoint, CGPoint)
        case close
    }

    struct Case {
        let width: CGFloat
        let height: CGFloat
        let radius: CGFloat
        let elements: [Element]

        var rect: CGRect {
            CGRect(origin: SquircleReference.rectOrigin, size: CGSize(width: width, height: height))
        }

        /// The frozen reference rebuilt as a real `CGPath`.
        var path: CGPath {
            let p = CGMutablePath()
            for e in elements {
                switch e {
                case .move(let a): p.move(to: a)
                case .line(let a): p.addLine(to: a)
                case .curve(let c1, let c2, let a): p.addCurve(to: a, control1: c1, control2: c2)
                case .close: p.closeSubpath()
                }
            }
            return p
        }
    }

    static let cases: [Case] = [
        Case(width: 402.0, height: 874.0, radius: 62.31, elements: [
            .move(CGPoint(x: 415.250000, y: 429.500000)),
            .line(CGPoint(x: 415.250000, y: 771.248887)),
            .curve(CGPoint(x: 415.250000, y: 798.676188), CGPoint(x: 415.250000, y: 812.389559), CGPoint(x: 410.582271, y: 827.151610)),
            .curve(CGPoint(x: 404.715871, y: 843.269336), CGPoint(x: 392.019336, y: 855.965871), CGPoint(x: 375.901610, y: 861.832271)),
            .curve(CGPoint(x: 361.139559, y: 866.500000), CGPoint(x: 347.426188, y: 866.500000), CGPoint(x: 319.998887, y: 866.500000)),
            .line(CGPoint(x: 108.501113, y: 866.500000)),
            .curve(CGPoint(x: 81.073812, y: 866.500000), CGPoint(x: 67.360441, y: 866.500000), CGPoint(x: 52.598390, y: 861.832271)),
            .curve(CGPoint(x: 36.480664, y: 855.965871), CGPoint(x: 23.784129, y: 843.269336), CGPoint(x: 17.917729, y: 827.151610)),
            .curve(CGPoint(x: 13.250000, y: 812.389559), CGPoint(x: 13.250000, y: 798.676188), CGPoint(x: 13.250000, y: 771.248887)),
            .line(CGPoint(x: 13.250000, y: 87.751113)),
            .curve(CGPoint(x: 13.250000, y: 60.323812), CGPoint(x: 13.250000, y: 46.610441), CGPoint(x: 17.917729, y: 31.848390)),
            .curve(CGPoint(x: 23.784129, y: 15.730664), CGPoint(x: 36.480664, y: 3.034129), CGPoint(x: 52.598390, y: -2.832271)),
            .curve(CGPoint(x: 67.360441, y: -7.500000), CGPoint(x: 81.073812, y: -7.500000), CGPoint(x: 108.501113, y: -7.500000)),
            .line(CGPoint(x: 319.998887, y: -7.500000)),
            .curve(CGPoint(x: 347.426188, y: -7.500000), CGPoint(x: 361.139559, y: -7.500000), CGPoint(x: 375.901610, y: -2.832271)),
            .curve(CGPoint(x: 392.019336, y: 3.034129), CGPoint(x: 404.715871, y: 15.730664), CGPoint(x: 410.582271, y: 31.848390)),
            .curve(CGPoint(x: 415.250000, y: 46.610441), CGPoint(x: 415.250000, y: 60.323812), CGPoint(x: 415.250000, y: 87.751113)),
            .close,
        ]),
        Case(width: 436.0, height: 908.0, radius: 80.61, elements: [
            .move(CGPoint(x: 449.250000, y: 446.500000)),
            .line(CGPoint(x: 449.250000, y: 777.274319)),
            .curve(CGPoint(x: 449.250000, y: 812.756820), CGPoint(x: 449.250000, y: 830.497711), CGPoint(x: 443.211392, y: 849.595270)),
            .curve(CGPoint(x: 435.622073, y: 870.446656), CGPoint(x: 419.196656, y: 886.872073), CGPoint(x: 398.345270, y: 894.461392)),
            .curve(CGPoint(x: 379.247711, y: 900.500000), CGPoint(x: 361.506820, y: 900.500000), CGPoint(x: 326.024319, y: 900.500000)),
            .line(CGPoint(x: 136.475681, y: 900.500000)),
            .curve(CGPoint(x: 100.993180, y: 900.500000), CGPoint(x: 83.252289, y: 900.500000), CGPoint(x: 64.154730, y: 894.461392)),
            .curve(CGPoint(x: 43.303344, y: 886.872073), CGPoint(x: 26.877927, y: 870.446656), CGPoint(x: 19.288608, y: 849.595270)),
            .curve(CGPoint(x: 13.250000, y: 830.497711), CGPoint(x: 13.250000, y: 812.756820), CGPoint(x: 13.250000, y: 777.274319)),
            .line(CGPoint(x: 13.250000, y: 115.725681)),
            .curve(CGPoint(x: 13.250000, y: 80.243180), CGPoint(x: 13.250000, y: 62.502289), CGPoint(x: 19.288608, y: 43.404730)),
            .curve(CGPoint(x: 26.877927, y: 22.553344), CGPoint(x: 43.303344, y: 6.127927), CGPoint(x: 64.154730, y: -1.461392)),
            .curve(CGPoint(x: 83.252289, y: -7.500000), CGPoint(x: 100.993180, y: -7.500000), CGPoint(x: 136.475681, y: -7.500000)),
            .line(CGPoint(x: 326.024319, y: -7.500000)),
            .curve(CGPoint(x: 361.506820, y: -7.500000), CGPoint(x: 379.247711, y: -7.500000), CGPoint(x: 398.345270, y: -1.461392)),
            .curve(CGPoint(x: 419.196656, y: 6.127927), CGPoint(x: 435.622073, y: 22.553344), CGPoint(x: 443.211392, y: 43.404730)),
            .curve(CGPoint(x: 449.250000, y: 62.502289), CGPoint(x: 449.250000, y: 80.243180), CGPoint(x: 449.250000, y: 115.725681)),
            .close,
        ]),
        Case(width: 1280.0, height: 800.0, radius: 24.0, elements: [
            .move(CGPoint(x: 1293.250000, y: 392.500000)),
            .line(CGPoint(x: 1293.250000, y: 755.812041)),
            .curve(CGPoint(x: 1293.250000, y: 766.376240), CGPoint(x: 1293.250000, y: 771.658232), CGPoint(x: 1291.452126, y: 777.344144)),
            .curve(CGPoint(x: 1289.192560, y: 783.552224), CGPoint(x: 1284.302224, y: 788.442560), CGPoint(x: 1278.094144, y: 790.702126)),
            .curve(CGPoint(x: 1272.408232, y: 792.500000), CGPoint(x: 1267.126240, y: 792.500000), CGPoint(x: 1256.562041, y: 792.500000)),
            .line(CGPoint(x: 49.937959, y: 792.500000)),
            .curve(CGPoint(x: 39.373760, y: 792.500000), CGPoint(x: 34.091768, y: 792.500000), CGPoint(x: 28.405856, y: 790.702126)),
            .curve(CGPoint(x: 22.197776, y: 788.442560), CGPoint(x: 17.307440, y: 783.552224), CGPoint(x: 15.047874, y: 777.344144)),
            .curve(CGPoint(x: 13.250000, y: 771.658232), CGPoint(x: 13.250000, y: 766.376240), CGPoint(x: 13.250000, y: 755.812041)),
            .line(CGPoint(x: 13.250000, y: 29.187959)),
            .curve(CGPoint(x: 13.250000, y: 18.623760), CGPoint(x: 13.250000, y: 13.341768), CGPoint(x: 15.047874, y: 7.655856)),
            .curve(CGPoint(x: 17.307440, y: 1.447776), CGPoint(x: 22.197776, y: -3.442560), CGPoint(x: 28.405856, y: -5.702126)),
            .curve(CGPoint(x: 34.091768, y: -7.500000), CGPoint(x: 39.373760, y: -7.500000), CGPoint(x: 49.937959, y: -7.500000)),
            .line(CGPoint(x: 1256.562041, y: -7.500000)),
            .curve(CGPoint(x: 1267.126240, y: -7.500000), CGPoint(x: 1272.408232, y: -7.500000), CGPoint(x: 1278.094144, y: -5.702126)),
            .curve(CGPoint(x: 1284.302224, y: -3.442560), CGPoint(x: 1289.192560, y: 1.447776), CGPoint(x: 1291.452126, y: 7.655856)),
            .curve(CGPoint(x: 1293.250000, y: 13.341768), CGPoint(x: 1293.250000, y: 18.623760), CGPoint(x: 1293.250000, y: 29.187959)),
            .close,
        ]),
        Case(width: 37.5, height: 12.5, radius: 6.25, elements: [
            .move(CGPoint(x: 50.750000, y: -1.250000)),
            .line(CGPoint(x: 50.750000, y: -1.250000)),
            .curve(CGPoint(x: 50.750000, y: -1.000000), CGPoint(x: 50.750000, y: -0.125000), CGPoint(x: 50.281804, y: 1.053163)),
            .curve(CGPoint(x: 49.693375, y: 2.669850), CGPoint(x: 48.419850, y: 3.943375), CGPoint(x: 46.803163, y: 4.531804)),
            .curve(CGPoint(x: 45.322456, y: 5.000000), CGPoint(x: 43.946937, y: 5.000000), CGPoint(x: 41.195844, y: 5.000000)),
            .line(CGPoint(x: 22.804156, y: 5.000000)),
            .curve(CGPoint(x: 20.053063, y: 5.000000), CGPoint(x: 18.677544, y: 5.000000), CGPoint(x: 17.196837, y: 4.531804)),
            .curve(CGPoint(x: 15.580150, y: 3.943375), CGPoint(x: 14.306625, y: 2.669850), CGPoint(x: 13.718196, y: 1.053163)),
            .curve(CGPoint(x: 13.250000, y: -0.125000), CGPoint(x: 13.250000, y: -1.000000), CGPoint(x: 13.250000, y: -1.250000)),
            .line(CGPoint(x: 13.250000, y: -1.250000)),
            .curve(CGPoint(x: 13.250000, y: -1.500000), CGPoint(x: 13.250000, y: -2.375000), CGPoint(x: 13.718196, y: -3.553163)),
            .curve(CGPoint(x: 14.306625, y: -5.169850), CGPoint(x: 15.580150, y: -6.443375), CGPoint(x: 17.196837, y: -7.031804)),
            .curve(CGPoint(x: 18.677544, y: -7.500000), CGPoint(x: 20.053063, y: -7.500000), CGPoint(x: 22.804156, y: -7.500000)),
            .line(CGPoint(x: 41.195844, y: -7.500000)),
            .curve(CGPoint(x: 43.946937, y: -7.500000), CGPoint(x: 45.322456, y: -7.500000), CGPoint(x: 46.803163, y: -7.031804)),
            .curve(CGPoint(x: 48.419850, y: -6.443375), CGPoint(x: 49.693375, y: -5.169850), CGPoint(x: 50.281804, y: -3.553163)),
            .curve(CGPoint(x: 50.750000, y: -2.375000), CGPoint(x: 50.750000, y: -1.500000), CGPoint(x: 50.750000, y: -1.250000)),
            .close,
        ]),
        Case(width: 200.0, height: 200.0, radius: 150.0, elements: [
            .move(CGPoint(x: 213.250000, y: 92.500000)),
            .line(CGPoint(x: 213.250000, y: 92.500000)),
            .curve(CGPoint(x: 213.250000, y: 96.500002), CGPoint(x: 213.250000, y: 110.500001), CGPoint(x: 205.758860, y: 129.350601)),
            .curve(CGPoint(x: 196.343999, y: 155.217599), CGPoint(x: 175.967599, y: 175.593999), CGPoint(x: 150.100601, y: 185.008860)),
            .curve(CGPoint(x: 131.250001, y: 192.500000), CGPoint(x: 117.250002, y: 192.500000), CGPoint(x: 113.250000, y: 192.500000)),
            .line(CGPoint(x: 113.250000, y: 192.500000)),
            .curve(CGPoint(x: 109.249998, y: 192.500000), CGPoint(x: 95.249999, y: 192.500000), CGPoint(x: 76.399399, y: 185.008860)),
            .curve(CGPoint(x: 50.532401, y: 175.593999), CGPoint(x: 30.156001, y: 155.217599), CGPoint(x: 20.741140, y: 129.350601)),
            .curve(CGPoint(x: 13.250000, y: 110.500001), CGPoint(x: 13.250000, y: 96.500002), CGPoint(x: 13.250000, y: 92.500000)),
            .line(CGPoint(x: 13.250000, y: 92.500000)),
            .curve(CGPoint(x: 13.250000, y: 88.499998), CGPoint(x: 13.250000, y: 74.499999), CGPoint(x: 20.741140, y: 55.649399)),
            .curve(CGPoint(x: 30.156001, y: 29.782401), CGPoint(x: 50.532401, y: 9.406001), CGPoint(x: 76.399399, y: -0.008860)),
            .curve(CGPoint(x: 95.249999, y: -7.500000), CGPoint(x: 109.249998, y: -7.500000), CGPoint(x: 113.250000, y: -7.500000)),
            .line(CGPoint(x: 113.250000, y: -7.500000)),
            .curve(CGPoint(x: 117.250002, y: -7.500000), CGPoint(x: 131.250001, y: -7.500000), CGPoint(x: 150.100601, y: -0.008860)),
            .curve(CGPoint(x: 175.967599, y: 9.406001), CGPoint(x: 196.343999, y: 29.782401), CGPoint(x: 205.758860, y: 55.649399)),
            .curve(CGPoint(x: 213.250000, y: 74.499999), CGPoint(x: 213.250000, y: 88.499998), CGPoint(x: 213.250000, y: 92.500000)),
            .close,
        ]),
        Case(width: 100.0, height: 300.0, radius: 50.0, elements: [
            .move(CGPoint(x: 113.250000, y: 142.500000)),
            .line(CGPoint(x: 113.250000, y: 216.066753)),
            .curve(CGPoint(x: 113.250000, y: 238.075500), CGPoint(x: 113.250000, y: 249.079649), CGPoint(x: 109.504430, y: 260.925301)),
            .curve(CGPoint(x: 104.797000, y: 273.858799), CGPoint(x: 94.608799, y: 284.047000), CGPoint(x: 81.675301, y: 288.754430)),
            .curve(CGPoint(x: 72.250000, y: 292.500000), CGPoint(x: 65.250001, y: 292.500000), CGPoint(x: 63.250000, y: 292.500000)),
            .line(CGPoint(x: 63.250000, y: 292.500000)),
            .curve(CGPoint(x: 61.249999, y: 292.500000), CGPoint(x: 54.250000, y: 292.500000), CGPoint(x: 44.824699, y: 288.754430)),
            .curve(CGPoint(x: 31.891201, y: 284.047000), CGPoint(x: 21.703000, y: 273.858799), CGPoint(x: 16.995570, y: 260.925301)),
            .curve(CGPoint(x: 13.250000, y: 249.079649), CGPoint(x: 13.250000, y: 238.075500), CGPoint(x: 13.250000, y: 216.066753)),
            .line(CGPoint(x: 13.250000, y: 68.933247)),
            .curve(CGPoint(x: 13.250000, y: 46.924500), CGPoint(x: 13.250000, y: 35.920351), CGPoint(x: 16.995570, y: 24.074699)),
            .curve(CGPoint(x: 21.703000, y: 11.141201), CGPoint(x: 31.891201, y: 0.953000), CGPoint(x: 44.824699, y: -3.754430)),
            .curve(CGPoint(x: 54.250000, y: -7.500000), CGPoint(x: 61.249999, y: -7.500000), CGPoint(x: 63.250000, y: -7.500000)),
            .line(CGPoint(x: 63.250000, y: -7.500000)),
            .curve(CGPoint(x: 65.250001, y: -7.500000), CGPoint(x: 72.250000, y: -7.500000), CGPoint(x: 81.675301, y: -3.754430)),
            .curve(CGPoint(x: 94.608799, y: 0.953000), CGPoint(x: 104.797000, y: 11.141201), CGPoint(x: 109.504430, y: 24.074699)),
            .curve(CGPoint(x: 113.250000, y: 35.920351), CGPoint(x: 113.250000, y: 46.924500), CGPoint(x: 113.250000, y: 68.933247)),
            .close,
        ]),
        Case(width: 300.0, height: 60.0, radius: 31.0, elements: [
            .move(CGPoint(x: 313.250000, y: 22.500000)),
            .line(CGPoint(x: 313.250000, y: 22.500000)),
            .curve(CGPoint(x: 313.250000, y: 23.700001), CGPoint(x: 313.250000, y: 27.900000), CGPoint(x: 311.002658, y: 33.555180)),
            .curve(CGPoint(x: 308.178200, y: 41.315280), CGPoint(x: 302.065280, y: 47.428200), CGPoint(x: 294.305180, y: 50.252658)),
            .curve(CGPoint(x: 287.197790, y: 52.500000), CGPoint(x: 280.595300, y: 52.500000), CGPoint(x: 267.390052, y: 52.500000)),
            .line(CGPoint(x: 59.109948, y: 52.500000)),
            .curve(CGPoint(x: 45.904700, y: 52.500000), CGPoint(x: 39.302210, y: 52.500000), CGPoint(x: 32.194820, y: 50.252658)),
            .curve(CGPoint(x: 24.434720, y: 47.428200), CGPoint(x: 18.321800, y: 41.315280), CGPoint(x: 15.497342, y: 33.555180)),
            .curve(CGPoint(x: 13.250000, y: 27.900000), CGPoint(x: 13.250000, y: 23.700001), CGPoint(x: 13.250000, y: 22.500000)),
            .line(CGPoint(x: 13.250000, y: 22.500000)),
            .curve(CGPoint(x: 13.250000, y: 21.299999), CGPoint(x: 13.250000, y: 17.100000), CGPoint(x: 15.497342, y: 11.444820)),
            .curve(CGPoint(x: 18.321800, y: 3.684720), CGPoint(x: 24.434720, y: -2.428200), CGPoint(x: 32.194820, y: -5.252658)),
            .curve(CGPoint(x: 39.302210, y: -7.500000), CGPoint(x: 45.904700, y: -7.500000), CGPoint(x: 59.109948, y: -7.500000)),
            .line(CGPoint(x: 267.390052, y: -7.500000)),
            .curve(CGPoint(x: 280.595300, y: -7.500000), CGPoint(x: 287.197790, y: -7.500000), CGPoint(x: 294.305180, y: -5.252658)),
            .curve(CGPoint(x: 302.065280, y: -2.428200), CGPoint(x: 308.178200, y: 3.684720), CGPoint(x: 311.002658, y: 11.444820)),
            .curve(CGPoint(x: 313.250000, y: 17.100000), CGPoint(x: 313.250000, y: 21.299999), CGPoint(x: 313.250000, y: 22.500000)),
            .close,
        ]),
        Case(width: 80.0, height: 80.0, radius: 1.0, elements: [
            .move(CGPoint(x: 93.250000, y: 32.500000)),
            .line(CGPoint(x: 93.250000, y: 70.971335)),
            .curve(CGPoint(x: 93.250000, y: 71.411510), CGPoint(x: 93.250000, y: 71.631593), CGPoint(x: 93.175089, y: 71.868506)),
            .curve(CGPoint(x: 93.080940, y: 72.127176), CGPoint(x: 92.877176, y: 72.330940), CGPoint(x: 92.618506, y: 72.425089)),
            .curve(CGPoint(x: 92.381593, y: 72.500000), CGPoint(x: 92.161510, y: 72.500000), CGPoint(x: 91.721335, y: 72.500000)),
            .line(CGPoint(x: 14.778665, y: 72.500000)),
            .curve(CGPoint(x: 14.338490, y: 72.500000), CGPoint(x: 14.118407, y: 72.500000), CGPoint(x: 13.881494, y: 72.425089)),
            .curve(CGPoint(x: 13.622824, y: 72.330940), CGPoint(x: 13.419060, y: 72.127176), CGPoint(x: 13.324911, y: 71.868506)),
            .curve(CGPoint(x: 13.250000, y: 71.631593), CGPoint(x: 13.250000, y: 71.411510), CGPoint(x: 13.250000, y: 70.971335)),
            .line(CGPoint(x: 13.250000, y: -5.971335)),
            .curve(CGPoint(x: 13.250000, y: -6.411510), CGPoint(x: 13.250000, y: -6.631593), CGPoint(x: 13.324911, y: -6.868506)),
            .curve(CGPoint(x: 13.419060, y: -7.127176), CGPoint(x: 13.622824, y: -7.330940), CGPoint(x: 13.881494, y: -7.425089)),
            .curve(CGPoint(x: 14.118407, y: -7.500000), CGPoint(x: 14.338490, y: -7.500000), CGPoint(x: 14.778665, y: -7.500000)),
            .line(CGPoint(x: 91.721335, y: -7.500000)),
            .curve(CGPoint(x: 92.161510, y: -7.500000), CGPoint(x: 92.381593, y: -7.500000), CGPoint(x: 92.618506, y: -7.425089)),
            .curve(CGPoint(x: 92.877176, y: -7.330940), CGPoint(x: 93.080940, y: -7.127176), CGPoint(x: 93.175089, y: -6.868506)),
            .curve(CGPoint(x: 93.250000, y: -6.631593), CGPoint(x: 93.250000, y: -6.411510), CGPoint(x: 93.250000, y: -5.971335)),
            .close,
        ]),
    ]
}
