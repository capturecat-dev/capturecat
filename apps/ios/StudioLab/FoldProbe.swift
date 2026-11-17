import UIKit

/// `--fold-probe` — logs what UIKit reports about the display this lab runs
/// on: size classes, safe area, the vertical-bar edge and its layout region,
/// and every reserved region (crease = `.division`, sensor = `.occlusion`).
/// Run on the iPhone Duo simulator to read the real values the fold layout
/// is built on.
@MainActor
enum FoldProbe {
    static func start(_ arguments: [String], lab: LabViewController) -> Bool {
        guard arguments.contains("--fold-probe") else { return false }
        setbuf(stdout, nil)
        Task { @MainActor in
            await LabTime.settle(1.0)
            report(lab.view)
            // `--fold-probe --editor`: the real editor, full screen, left up
            // for a screenshot; logs its arrangement and regions.
            guard arguments.contains("--editor") else { exit(0) }
            if #available(iOS 26, *), let editor = await EditorResizeLab.openEditor(in: FileManager.default.temporaryDirectory.appendingPathComponent("fold-probe", isDirectory: true)) {
                editor.modalPresentationStyle = .fullScreen
                lab.present(editor, animated: false)
                // `--landscape`: a phone on its side (compact height).
                if arguments.contains("--landscape") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
                        editor.setNeedsUpdateOfSupportedInterfaceOrientations()
                        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
                            print("FOLD-PROBE landscape refused: \(error)")
                        }
                    }
                }
                // `--open-pane <Tab>`: that pane's tool tapped (its panel open);
                // `--select-zoom`: the first zoom block selected (the context keys).
                let after = arguments.contains("--landscape") ? 3.5 : 2.0
                if let i = arguments.firstIndex(of: "--open-pane"), arguments.indices.contains(i + 1),
                   let tab = InspectorTab.allCases.first(where: { $0.rawValue.lowercased() == arguments[i + 1].lowercased() }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                        if let key = editor.toolBar.key(for: .pane(tab)) { key.sendActions(for: .touchUpInside) } else { editor.openPanel(tab) }
                    }
                }
                // `--tall`: the open panel dragged to its TALL detent.
                if arguments.contains("--tall") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + after + 1.0) { editor.setPanelDetent(.tall) }
                }
                if arguments.contains("--select-zoom") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                        editor.timeline.canvas.setOpenLane(.effects, animated: true)
                        editor.selection.selectedZoomID = editor.project.zoomRegions.first?.id
                    }
                }
                if arguments.contains("--expanded") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + after) { editor.setPreviewExpanded(true) }
                }
                for _ in 0..<600 {
                    await LabTime.settle(1.0)
                    let root = editor.view!
                    func f(_ v: UIView) -> CGRect { root.convert(v.bounds, from: v).integral }
                    print("FOLD-PROBE editor bounds=\(root.bounds.size) arrangement=\(editor.activeArrangement?.rawValue ?? "nil") crease=\(editor.crease.map { "\($0)" } ?? "none") stage=\(f(editor.stageCard)) timeline=\(f(editor.timelineContainer)) inspector=\(f(editor.inspectorContainer)) toolBar=\(f(editor.toolBar)) panel=\(editor.isPanelOpen ? f(editor.inspector.view) : .zero) title=\(f(editor.header.probeTitleView))")
                }
            }
            exit(0)
        }
        return true
    }

    static func report(_ view: UIView) {
        let t = view.traitCollection
        func sc(_ c: UIUserInterfaceSizeClass) -> String { c == .regular ? "regular" : c == .compact ? "compact" : "unspecified" }
        print("FOLD-PROBE bounds=\(view.bounds.size) h=\(sc(t.horizontalSizeClass)) v=\(sc(t.verticalSizeClass))")
        print("FOLD-PROBE safeArea=\(view.safeAreaInsets) window=\(view.window?.bounds.size ?? .zero)")
        if let screen = view.window?.windowScene?.screen {
            print("FOLD-PROBE screen=\(screen.bounds.size) scale=\(screen.scale)")
        }
        if #available(iOS 27.1, *) {
            let edge: String
            switch t.verticalBarEdge {
            case .leading: edge = "leading"
            case .trailing: edge = "trailing"
            default: edge = "unspecified"
            }
            print("FOLD-PROBE verticalBarEdge=\(edge)")
            if #available(iOS 27.2, *) {
                for (name, e) in [("leading", NSDirectionalRectEdge.leading), ("trailing", .trailing), ("bottom", .bottom)] {
                    print("FOLD-PROBE bar(\(name)) insets=\(view.directionalEdgeInsets(for: .bar(onEdge: e))) guide=\(view.layoutGuide(for: .bar(onEdge: e)).layoutFrame)")
                }
            }
            for (name, kind) in [("division", UIView.ReservedRegion.Kind.division), ("occlusion", .occlusion)] {
                let regions = view.reservedRegions(kind: kind, options: .includeInactive)
                print("FOLD-PROBE \(name) count=\(regions.count)")
                for r in regions {
                    print("FOLD-PROBE   \(name) frame=\(r.frame) margins=\(r.margins) active=\(r.isActive)")
                }
            }
        } else {
            print("FOLD-PROBE iOS < 27.1: no fold APIs")
        }
    }
}
