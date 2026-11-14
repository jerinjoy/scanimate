import SwiftUI

// Platen dimensions in WSD 1/1000-inch units (Letter: 8.5" × 11")
private let wsdBedWidth = ScanRegion.bedWidth
private let wsdBedHeight = ScanRegion.bedHeight

/// Lets the user draw, move and resize the ScanRegion on top of the Overview.
/// There is no default ScanRegion: until the user draws one, only a hint shows.
struct SelectionOverlayView: View {
    @Binding var region: ScanRegion?
    @State private var dragStartRegion: ScanRegion?
    /// True while the user is drawing a new ScanRegion. The binding is left
    /// untouched until the drag ends, so a drag that ends too small simply
    /// leaves the previous ScanRegion (or nil) in place.
    @State private var isDrawing = false
    @State private var drawingRegion: ScanRegion?

    static let bedWidth: CGFloat = CGFloat(wsdBedWidth)
    static let bedHeight: CGFloat = CGFloat(wsdBedHeight)
    private let handleSize: CGFloat = 10
    private let handleHitSize: CGFloat = 20
    private let minSelectionWSD = ScanRegion.minimumSide

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack(alignment: .topLeading) {
                // Bottom layer: the body and handle gestures drawn above it keep priority.
                drawLayer(containerSize: size)
                if isDrawing {
                    if let drawingRegion {
                        box(for: drawingRegion, containerSize: size)
                    }
                } else if let region {
                    box(for: region, containerSize: size)
                    bodyDrag(region: region, containerSize: size)
                    handleViews(region: region, containerSize: size)
                } else {
                    hint
                }
            }
        }
    }

    // MARK: - Sub-views

    private func drawLayer(containerSize: CGSize) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        isDrawing = true
                        // Live box from the press point to the pointer, shown at any size.
                        drawingRegion = ScanRegion.fromDrag(
                            start: value.startLocation,
                            current: value.location,
                            containerSize: containerSize,
                            minSize: 1
                        )
                    }
                    .onEnded { value in
                        if let drawn = ScanRegion.fromDrag(
                            start: value.startLocation,
                            current: value.location,
                            containerSize: containerSize,
                            minSize: minSelectionWSD
                        ) {
                            region = drawn
                        }
                        isDrawing = false
                        drawingRegion = nil
                    }
            )
    }

    private var hint: some View {
        Text("Drag to select the area to scan")
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func box(for shown: ScanRegion, containerSize: CGSize) -> some View {
        let rect = wsdToScreen(shown, in: containerSize)
        dimOverlay(selectionRect: rect, containerSize: containerSize)
        selectionBorder(rect: rect)
    }

    private func dimOverlay(selectionRect: CGRect, containerSize: CGSize) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: containerSize))
            path.addRect(selectionRect)
        }
        .fill(style: FillStyle(eoFill: true))
        .foregroundStyle(Color.black.opacity(0.35))
        .allowsHitTesting(false)
    }

    private func selectionBorder(rect: CGRect) -> some View {
        Rectangle()
            .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.5)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }

    private func bodyDrag(region snapshot: ScanRegion, containerSize: CGSize) -> some View {
        let rect = wsdToScreen(snapshot, in: containerSize)
        // Leave the handles' hit areas (half of which lie inside the box) uncovered.
        let inset: CGFloat = handleHitSize / 2
        let innerW = max(rect.width - inset * 2, 1)
        let innerH = max(rect.height - inset * 2, 1)
        return Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: innerW, height: innerH)
            .position(x: rect.midX, y: rect.midY)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStartRegion == nil { dragStartRegion = snapshot }
                        guard let start = dragStartRegion else { return }
                        let (dx, dy) = screenToWSD(size: value.translation, containerSize: containerSize)
                        let newX = clamp(start.xOffset + dx, lo: 0, hi: wsdBedWidth - start.width)
                        let newY = clamp(start.yOffset + dy, lo: 0, hi: wsdBedHeight - start.height)
                        region = ScanRegion(xOffset: newX, yOffset: newY, width: start.width, height: start.height)
                    }
                    .onEnded { _ in dragStartRegion = nil }
            )
    }

    @ViewBuilder
    private func handleViews(region snapshot: ScanRegion, containerSize: CGSize) -> some View {
        let rect = wsdToScreen(snapshot, in: containerSize)
        ForEach(Handle.allCases, id: \.self) { handle in
            handleCircle(at: handle.position(in: rect))
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if dragStartRegion == nil { dragStartRegion = snapshot }
                            guard let start = dragStartRegion else { return }
                            let (dx, dy) = screenToWSD(size: value.translation, containerSize: containerSize)
                            region = handle.updatedRegion(start: start, dx: dx, dy: dy, minSize: minSelectionWSD)
                        }
                        .onEnded { _ in dragStartRegion = nil }
                )
        }
    }

    private func handleCircle(at position: CGPoint) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: handleSize, height: handleSize)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
            // 10 pt visual, 20 pt hit area.
            .frame(width: handleHitSize, height: handleHitSize)
            .contentShape(Rectangle())
            .position(position)
    }

    // MARK: - Coordinate helpers

    private func wsdToScreen(_ r: ScanRegion, in size: CGSize) -> CGRect {
        CGRect(
            x: CGFloat(r.xOffset) * size.width / Self.bedWidth,
            y: CGFloat(r.yOffset) * size.height / Self.bedHeight,
            width: CGFloat(r.width) * size.width / Self.bedWidth,
            height: CGFloat(r.height) * size.height / Self.bedHeight
        )
    }

    private func screenToWSD(size: CGSize, containerSize: CGSize) -> (dx: Int, dy: Int) {
        (
            Int(size.width * Self.bedWidth / containerSize.width),
            Int(size.height * Self.bedHeight / containerSize.height)
        )
    }

    private func clamp(_ value: Int, lo: Int, hi: Int) -> Int {
        max(lo, min(hi, value))
    }
}

// MARK: - Handle enum

enum Handle: CaseIterable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    func position(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
        case .top:         return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
        case .left:        return CGPoint(x: rect.minX, y: rect.midY)
        case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottom:      return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    func updatedRegion(start: ScanRegion, dx: Int, dy: Int, minSize: Int) -> ScanRegion {
        var x1 = start.xOffset
        var y1 = start.yOffset
        var x2 = start.xOffset + start.width
        var y2 = start.yOffset + start.height

        switch self {
        case .topLeft:
            x1 = max(0, min(x1 + dx, x2 - minSize))
            y1 = max(0, min(y1 + dy, y2 - minSize))
        case .top:
            y1 = max(0, min(y1 + dy, y2 - minSize))
        case .topRight:
            x2 = max(x1 + minSize, min(x2 + dx, wsdBedWidth))
            y1 = max(0, min(y1 + dy, y2 - minSize))
        case .left:
            x1 = max(0, min(x1 + dx, x2 - minSize))
        case .right:
            x2 = max(x1 + minSize, min(x2 + dx, wsdBedWidth))
        case .bottomLeft:
            x1 = max(0, min(x1 + dx, x2 - minSize))
            y2 = max(y1 + minSize, min(y2 + dy, wsdBedHeight))
        case .bottom:
            y2 = max(y1 + minSize, min(y2 + dy, wsdBedHeight))
        case .bottomRight:
            x2 = max(x1 + minSize, min(x2 + dx, wsdBedWidth))
            y2 = max(y1 + minSize, min(y2 + dy, wsdBedHeight))
        }

        return ScanRegion(xOffset: x1, yOffset: y1, width: x2 - x1, height: y2 - y1)
    }
}
