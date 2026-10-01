import UIKit

/// Fotoro-style staggered column masonry: equal column widths, height from
/// each photo's aspect ratio, round-robin fill (index → column index % N).
final class MasonryLayout: UICollectionViewLayout {
    weak var delegate: MasonryLayoutDelegate?

    /// Ideal minimum column width. Used when `preferredColumnCount` is nil.
    var idealColumnWidth: CGFloat = 120 {
        didSet { if oldValue != idealColumnWidth { invalidateLayout() } }
    }

    /// When set, forces this many equal-width columns (fills the available width).
    var preferredColumnCount: Int? {
        didSet {
            if oldValue != preferredColumnCount { invalidateLayout() }
        }
    }

    var columnSpacing: CGFloat = 4 {
        didSet { if oldValue != columnSpacing { invalidateLayout() } }
    }

    var rowSpacing: CGFloat = 4 {
        didSet { if oldValue != rowSpacing { invalidateLayout() } }
    }

    var sectionInset: UIEdgeInsets = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4) {
        didSet { invalidateLayout() }
    }

    private var attributesCache: [UICollectionViewLayoutAttributes] = []
    private var contentHeight: CGFloat = 0
    private var contentWidth: CGFloat = 0
    private(set) var columnWidth: CGFloat = 0
    private(set) var columnCount: Int = 1

    override var collectionViewContentSize: CGSize {
        CGSize(width: contentWidth, height: contentHeight)
    }

    override func prepare() {
        guard let collectionView else { return }
        let width = collectionView.bounds.width
        guard width > 0 else { return }

        contentWidth = width
        attributesCache.removeAll(keepingCapacity: true)

        let available = max(1, width - sectionInset.left - sectionInset.right)
        let count: Int
        if let preferred = preferredColumnCount, preferred > 0 {
            count = preferred
        } else {
            count = max(1, Int(floor((available + columnSpacing) / (idealColumnWidth + columnSpacing))))
        }
        columnCount = count
        let colW = (available - CGFloat(count - 1) * columnSpacing) / CGFloat(count)
        columnWidth = colW

        let scale = collectionView.traitCollection.displayScale
        func align(_ v: CGFloat) -> CGFloat {
            guard scale > 0 else { return v }
            return (v * scale).rounded() / scale
        }

        var heights = [CGFloat](repeating: sectionInset.top, count: count)
        let itemCount = collectionView.numberOfItems(inSection: 0)

        for index in 0..<itemCount {
            let column = index % count
            let x = sectionInset.left + CGFloat(column) * (colW + columnSpacing)
            let minX = align(x)
            let maxX = align(x + colW)
            let aspect = delegate?.masonryLayout(self, aspectRatioForItemAt: index) ?? 1
            let clamped = min(max(aspect, 0.2), 5)
            let height = align(colW * clamped)

            let frame = CGRect(x: minX, y: heights[column], width: maxX - minX, height: height)
            let attrs = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attrs.frame = frame
            attributesCache.append(attrs)
            heights[column] += height + rowSpacing
        }

        contentHeight = itemCount == 0
            ? 0
            : (heights.max() ?? 0) - rowSpacing + sectionInset.bottom
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        attributesCache.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard attributesCache.indices.contains(indexPath.item) else { return nil }
        return attributesCache[indexPath.item]
    }

    /// Data indices in visual grid order (top → bottom, left → right).
    func indicesInVisualOrder() -> [Int] {
        guard !attributesCache.isEmpty else { return [] }
        return attributesCache.indices.sorted { a, b in
            let fa = attributesCache[a].frame
            let fb = attributesCache[b].frame
            if abs(fa.minY - fb.minY) > 0.5 {
                return fa.minY < fb.minY
            }
            return fa.minX < fb.minX
        }
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let collectionView else { return false }
        return abs(newBounds.width - collectionView.bounds.width) > 0.5
    }

    override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        if let collectionView, abs(newBounds.width - collectionView.bounds.width) > 0.5 {
            attributesCache.removeAll(keepingCapacity: true)
        }
        return context
    }
}

protocol MasonryLayoutDelegate: AnyObject {
    /// Height ÷ width for the item (Fotoro convention).
    func masonryLayout(_ layout: MasonryLayout, aspectRatioForItemAt index: Int) -> CGFloat
}
