//
//  VirtualDocument.swift
//  AlphaG3n
//

import Foundation
import UIKit
import CoreGraphics

// MARK: - VirtualDocument

public struct VirtualDocument: @unchecked Sendable {
    public let image: UIImage
    public let pageSize: CGSize
    public let groups: [Group]

    public init(image: UIImage, pageSize: CGSize, groups: [Group]) {
        self.image = image
        self.pageSize = pageSize
        self.groups = groups
    }

    public var parts: [Part] { groups.flatMap(\.parts) }
}

// MARK: - Nested types

public extension VirtualDocument {

    enum BlockLabel: String, Sendable, Hashable {
        case docTitle = "doc_title"
        case paragraphTitle = "paragraph_title"
        case text
        case image
        case header
        case headerImage = "header_image"
        case footer
        case footerImage = "footer_image"
        case visionFootnote = "vision_footnote"
        case asideText = "aside_text"
        case footnote
        case number
        case table
        case formula
        case chart
        case seal
        case unknown

        init(apiValue: String) {
            self = BlockLabel(rawValue: apiValue) ?? .unknown
        }
    }

    struct Group: Sendable, Identifiable, Hashable {
        public let id: Int
        public let parts: [Part]

        public init(id: Int, parts: [Part]) {
            self.id = id
            self.parts = parts
        }
    }

    enum Part: Sendable, Identifiable, Hashable {
        case text(TextPart)
        case image(ImagePart)

        public var id: Int {
            switch self {
            case .text(let p):  return p.id
            case .image(let p): return p.id
            }
        }

        public var label: BlockLabel {
            switch self {
            case .text(let p):  return p.label
            case .image(let p): return p.label
            }
        }

        public var bbox: CGRect {
            switch self {
            case .text(let p):  return p.bbox
            case .image(let p): return p.bbox
            }
        }

        public var polygon: [CGPoint] {
            switch self {
            case .text(let p):  return p.polygon
            case .image(let p): return p.polygon
            }
        }

        public var order: Int? {
            switch self {
            case .text(let p):  return p.order
            case .image(let p): return p.order
            }
        }
    }

    struct TextPart: Sendable, Identifiable, Hashable {
        public let id: Int
        public let label: BlockLabel
        public let content: String
        public let bbox: CGRect
        public let polygon: [CGPoint]
        public let order: Int?

        public init(
            id: Int,
            label: BlockLabel,
            content: String,
            bbox: CGRect,
            polygon: [CGPoint],
            order: Int?
        ) {
            self.id = id
            self.label = label
            self.content = content
            self.bbox = bbox
            self.polygon = polygon
            self.order = order
        }
    }

    struct ImagePart: Sendable, Identifiable, Hashable {
        public let id: Int
        public let label: BlockLabel
        public let bbox: CGRect
        public let polygon: [CGPoint]
        public let order: Int?
        /// Relative path of the cropped image asset embedded by the API
        /// (e.g. `imgs/img_in_image_box_2300_1828_2879_2438.jpg`), parsed
        /// out of the block's markdown `<img src="…">` snippet.
        public let extractedImageRef: String?

        public init(
            id: Int,
            label: BlockLabel,
            bbox: CGRect,
            polygon: [CGPoint],
            order: Int?,
            extractedImageRef: String?
        ) {
            self.id = id
            self.label = label
            self.bbox = bbox
            self.polygon = polygon
            self.order = order
            self.extractedImageRef = extractedImageRef
        }
    }
}

// MARK: - Decoder for the API's prunedResult payload

public extension VirtualDocument {

    struct PrunedResult: Decodable, Sendable {
        public let width: Int
        public let height: Int
        public let parsingResList: [RawBlock]

        public struct RawBlock: Decodable, Sendable {
            public let blockLabel: String
            public let blockContent: String
            public let blockBbox: [Double]
            public let blockId: Int
            public let blockOrder: Int?
            public let groupId: Int
            public let blockPolygonPoints: [[Double]]?

            enum CodingKeys: String, CodingKey {
                case blockLabel = "block_label"
                case blockContent = "block_content"
                case blockBbox = "block_bbox"
                case blockId = "block_id"
                case blockOrder = "block_order"
                case groupId = "group_id"
                case blockPolygonPoints = "block_polygon_points"
            }
        }

        enum CodingKeys: String, CodingKey {
            case width
            case height
            case parsingResList = "parsing_res_list"
        }
    }
}

// MARK: - Factory

public extension VirtualDocument {

    static let imageLabels: Set<BlockLabel> = [.image, .footerImage, .headerImage]

    static func make(from pruned: PrunedResult, image: UIImage) -> VirtualDocument {
        let pageSize = CGSize(width: pruned.width, height: pruned.height)

        var groupOrder: [Int] = []
        var grouped: [Int: [PrunedResult.RawBlock]] = [:]
        for block in pruned.parsingResList {
            if grouped[block.groupId] == nil {
                grouped[block.groupId] = []
                groupOrder.append(block.groupId)
            }
            grouped[block.groupId]?.append(block)
        }

        var groups: [Group] = groupOrder.map { gid in
            let blocks = (grouped[gid] ?? []).sorted { lhs, rhs in
                let l = lhs.blockOrder ?? .max
                let r = rhs.blockOrder ?? .max
                if l != r { return l < r }
                return lhs.blockId < rhs.blockId
            }
            return Group(id: gid, parts: blocks.map(Part.from(raw:)))
        }

        // Groups with at least one ordered block come first (in reading order);
        // unordered groups (images, decoration) sort to the end by group id.
        groups.sort { lhs, rhs in
            let l = lhs.parts.compactMap(\.order).min() ?? .max
            let r = rhs.parts.compactMap(\.order).min() ?? .max
            if l != r { return l < r }
            return lhs.id < rhs.id
        }

        return VirtualDocument(image: image, pageSize: pageSize, groups: groups)
    }
}

private extension VirtualDocument.Part {
    static func from(raw: VirtualDocument.PrunedResult.RawBlock) -> VirtualDocument.Part {
        let label = VirtualDocument.BlockLabel(apiValue: raw.blockLabel)
        let bbox = CGRect.from(bbox: raw.blockBbox)
        let polygon = (raw.blockPolygonPoints ?? []).compactMap { pair -> CGPoint? in
            guard pair.count >= 2 else { return nil }
            return CGPoint(x: pair[0], y: pair[1])
        }

        if VirtualDocument.imageLabels.contains(label) {
            return .image(.init(
                id: raw.blockId,
                label: label,
                bbox: bbox,
                polygon: polygon,
                order: raw.blockOrder,
                extractedImageRef: extractImageRef(from: raw.blockContent)
            ))
        }
        return .text(.init(
            id: raw.blockId,
            label: label,
            content: raw.blockContent,
            bbox: bbox,
            polygon: polygon,
            order: raw.blockOrder
        ))
    }
}

private func extractImageRef(from content: String) -> String? {
    guard let srcRange = content.range(of: "src=\"") else { return nil }
    let after = content[srcRange.upperBound...]
    guard let closing = after.firstIndex(of: "\"") else { return nil }
    return String(after[..<closing])
}

private extension CGRect {
    static func from(bbox: [Double]) -> CGRect {
        guard bbox.count >= 4 else { return .zero }
        let (x, y, r, b) = (bbox[0], bbox[1], bbox[2], bbox[3])
        return CGRect(x: x, y: y, width: r - x, height: b - y)
    }
}

// MARK: - Rendering

public extension VirtualDocument {

    /// Sendable color triple. UIColor isn't Sendable under strict concurrency,
    /// so the palette is stored as RGBA and materialised to UIColor at draw time.
    struct RGBA: Sendable, Hashable {
        public var r: CGFloat
        public var g: CGFloat
        public var b: CGFloat

        public init(r: CGFloat, g: CGFloat, b: CGFloat) {
            self.r = r; self.g = g; self.b = b
        }

        public func uiColor(alpha: CGFloat = 1) -> UIColor {
            UIColor(red: r, green: g, blue: b, alpha: alpha)
        }
    }

    struct RenderStyle: Sendable {
        public var lineWidth: CGFloat
        public var fillAlpha: CGFloat
        public var cornerRadius: CGFloat
        public var palette: [BlockLabel: RGBA]
        public var fallbackColor: RGBA
        public var drawPolygons: Bool

        public init(
            lineWidth: CGFloat = 8,
            fillAlpha: CGFloat = 0.25,
            cornerRadius: CGFloat = 16,
            palette: [BlockLabel: RGBA] = .pastel,
            fallbackColor: RGBA = .init(r: 0.5, g: 0.5, b: 0.5),
            drawPolygons: Bool = true
        ) {
            self.lineWidth = lineWidth
            self.fillAlpha = fillAlpha
            self.cornerRadius = cornerRadius
            self.palette = palette
            self.fallbackColor = fallbackColor
            self.drawPolygons = drawPolygons
        }

        public static let `default` = RenderStyle()
    }

    /// Draws the source image with a color-coded overlay for each part.
    /// Coordinates from the API are in `pageSize` space; they're scaled to the
    /// underlying image's pixel size at draw time.
    func render(style: RenderStyle = .default) -> UIImage {
        let canvasSize = image.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true

        let scaleX = pageSize.width  > 0 ? canvasSize.width  / pageSize.width  : 1
        let scaleY = pageSize.height > 0 ? canvasSize.height / pageSize.height : 1

        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: canvasSize))

            for group in groups {
                for part in group.parts {
                    let rgba = style.palette[part.label] ?? style.fallbackColor
                    let path = path(for: part, scaleX: scaleX, scaleY: scaleY, style: style)

                    rgba.uiColor(alpha: style.fillAlpha).setFill()
                    path.fill()
                    rgba.uiColor(alpha: 1).setStroke()
                    path.lineWidth = style.lineWidth
                    path.stroke()
                }
            }
        }
    }

    private func path(
        for part: Part,
        scaleX: CGFloat,
        scaleY: CGFloat,
        style: RenderStyle
    ) -> UIBezierPath {
        if style.drawPolygons, part.polygon.count >= 3 {
            let pts = part.polygon.map { CGPoint(x: $0.x * scaleX, y: $0.y * scaleY) }
            let path = UIBezierPath()
            path.move(to: pts[0])
            for p in pts.dropFirst() { path.addLine(to: p) }
            path.close()
            return path
        }
        let r = CGRect(
            x: part.bbox.minX * scaleX,
            y: part.bbox.minY * scaleY,
            width: part.bbox.width * scaleX,
            height: part.bbox.height * scaleY
        )
        return UIBezierPath(roundedRect: r, cornerRadius: style.cornerRadius)
    }
}

// MARK: - Default palette

public extension Dictionary
where Key == VirtualDocument.BlockLabel, Value == VirtualDocument.RGBA {

    /// Pastel palette tuned to roughly match a hand-annotated overlay aesthetic.
    static var pastel: [VirtualDocument.BlockLabel: VirtualDocument.RGBA] {
        [
            .docTitle:       .init(r: 0.72, g: 0.71, b: 0.93), // lavender
            .paragraphTitle: .init(r: 0.97, g: 0.69, b: 0.69), // salmon
            .text:           .init(r: 0.97, g: 0.74, b: 0.81), // pink
            .image:          .init(r: 0.65, g: 0.84, b: 0.94), // sky
            .header:         .init(r: 0.78, g: 0.95, b: 0.78), // mint
            .headerImage:    .init(r: 0.78, g: 0.95, b: 0.78), // mint
            .footer:         .init(r: 0.85, g: 0.75, b: 0.95), // light purple
            .footerImage:    .init(r: 0.97, g: 0.83, b: 0.69), // peach
            .visionFootnote: .init(r: 0.99, g: 0.86, b: 0.72), // light peach
            .asideText:      .init(r: 0.90, g: 0.90, b: 0.75), // pale yellow
            .footnote:       .init(r: 0.85, g: 0.85, b: 0.85),
            .number:         .init(r: 0.80, g: 0.80, b: 0.80),
            .table:          .init(r: 0.70, g: 0.90, b: 0.90), // teal
            .formula:        .init(r: 0.95, g: 0.80, b: 0.90), // rose
            .chart:          .init(r: 0.80, g: 0.90, b: 0.70), // pistachio
            .seal:           .init(r: 0.95, g: 0.65, b: 0.65), // coral
        ]
    }
}
