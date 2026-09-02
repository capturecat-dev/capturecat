import AppKit

/// `--drawon-test` — acceptance test for the Draw On build effect.
///
/// Asserts the failure modes the visual gates have been burned by:
///  • mid-flight, not settled: at p=0.5 the trim is a genuine PARTIAL stroke
///    set (more than empty, less than everything, interpolated pen tip);
///  • timeline-derived: combined() phase mid-window reports strokeProgress
///    strictly between 0 and 1 for enter AND exit (exit un-draws);
///  • other effects untouched: .pop keeps strokeProgress == 1;
///  • determinism: same inputs, same output.
enum DrawOnHarness {
    static func run() -> Never {
        setbuf(stdout, nil)
        var failures: [String] = []
        func check(_ ok: Bool, _ label: String) {
            print("DRAWON \(ok ? "ok" : "FAIL") \(label)")
            if !ok { failures.append(label) }
        }

        // Two strokes: 4 points + 2 points → total cost 6.
        let strokes: [[CodablePoint]] = [
            [.init(x: 0.0, y: 0.0), .init(x: 0.1, y: 0.0), .init(x: 0.2, y: 0.0), .init(x: 0.3, y: 0.0)],
            [.init(x: 0.5, y: 0.5), .init(x: 0.6, y: 0.5)],
        ]

        check(AnnotationRenderer.trimmedStrokes(strokes, progress: 0).isEmpty,
              "p=0 draws nothing")
        check(AnnotationRenderer.trimmedStrokes(strokes, progress: 1).count == 2
                && AnnotationRenderer.trimmedStrokes(strokes, progress: 1)[0].count == 4,
              "p=1 draws everything")

        let half = AnnotationRenderer.trimmedStrokes(strokes, progress: 0.5) // pen at 3.0 of 6
        check(half.count == 1, "p=0.5 is mid-stroke-one")
        check((half.first?.count ?? 0) > 1 && (half.first?.count ?? 9) < 4,
              "p=0.5 is a PARTIAL stroke (\(half.first?.count ?? -1) of 4 points)")
        let tip = AnnotationRenderer.trimmedStrokes(strokes, progress: 0.42).first?.last
        let wholeX = [0.0, 0.1, 0.2, 0.3]
        check(tip.map { !wholeX.contains($0.x) } == true,
              "pen tip is interpolated between recorded points (x=\(tip?.x ?? -1))")

        // Enter: mid-window strokeProgress strictly between 0 and 1.
        let enterMid = AnnotationEffectMath.combined(
            enter: .drawOn, exit: .none, start: 10, end: 20,
            at: 10 + AnnotationEffectMath.drawOnDuration / 2
        )
        check(enterMid.strokeProgress > 0.05 && enterMid.strokeProgress < 0.95,
              "enter mid-flight strokeProgress=\(enterMid.strokeProgress)")
        // Exit: un-draws near the end.
        let exitMid = AnnotationEffectMath.combined(
            enter: .none, exit: .drawOn, start: 10, end: 20,
            at: 20 - AnnotationEffectMath.drawOnDuration / 4
        )
        check(exitMid.strokeProgress > 0.05 && exitMid.strokeProgress < 0.5,
              "exit un-draw strokeProgress=\(exitMid.strokeProgress)")
        // Settled middle of the span: full drawing.
        let settled = AnnotationEffectMath.combined(enter: .drawOn, exit: .drawOn, start: 10, end: 20, at: 15)
        check(settled.strokeProgress == 1, "settled span shows the full drawing")
        // Other effects never trim.
        let pop = AnnotationEffectMath.phase(effect: .pop, progress: 0.5)
        check(pop.strokeProgress == 1, ".pop leaves strokes untrimmed")
        // Determinism.
        let a = AnnotationRenderer.trimmedStrokes(strokes, progress: 0.37)
        let b = AnnotationRenderer.trimmedStrokes(strokes, progress: 0.37)
        check(a == b, "deterministic for identical inputs")

        print(failures.isEmpty ? "DRAWON PASS" : "DRAWON FAIL \(failures.count)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
