import SwiftUI
import UIKit

struct BookPageCommand: Equatable {
    let id = UUID()
    var delta = 0
}

struct PagedBookView: UIViewControllerRepresentable {
    let text: String
    let sourceOffset: Int
    let position: Int
    let highlighted: NSRange?
    let follow: Bool
    let title: String
    let pages: Int
    let gutter: CGFloat
    let fold: Double
    let reduceMotion: Bool
    let command: BookPageCommand
    let onBrowse: (Int) -> Void
    let onPageInfo: (Int, Int) -> Void
    let onBoundary: (Int) -> Void

    func makeUIViewController(context: Context) -> BookPagerController { BookPagerController() }
    func updateUIViewController(_ controller: BookPagerController, context: Context) {
        controller.update(self)
    }
}

final class BookPagerController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    private(set) var pagination: BookPagination?
    private(set) var currentPage = 0
    private var configuration: PagedBookView?
    private var pager: UIPageViewController?
    private var cache: [Int: BookSheetController] = [:]
    private var signature = ""
    private var lastCommand: UUID?
    private var transitioning = false
    private var rotating = false
    private var pendingFollow = false
    private var followOffset: Int?
    private var lastSpokenOffset: Int?
    private var readingAnchor: Int?
    private var generation = UUID()
    private var isRTL = false
    private var reduced = false
    private var pageCount = 1
    private var step: Int { pageCount }
    private var groupSize: Int { reduced ? 1 : pageCount }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.accessibilityLabel = "Book pages"
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !rotating { pager?.view.frame = view.bounds; reflowIfNeeded() }
    }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        rotating = true
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            self.rotating = false
            self.signature = ""
            self.reflowIfNeeded()
            self.followVoice()
        }
    }
    func update(_ value: PagedBookView) {
        let previous = configuration
        let oldSource = previous?.sourceOffset
        let changedText = previous?.text != value.text || oldSource != value.sourceOffset
        if changedText { lastSpokenOffset = nil; readingAnchor = value.position }
        if previous?.position != value.position, value.highlighted == nil {
            lastSpokenOffset = nil; followOffset = value.position; readingAnchor = value.position
        }
        if let word = value.highlighted {
            lastSpokenOffset = word.location
            if value.follow { readingAnchor = word.location }
        }
        if previous?.follow == false && value.follow { followOffset = lastSpokenOffset ?? value.position }
        configuration = value
        loadViewIfNeeded()
        if oldSource != value.sourceOffset { signature = "" }
        reflowIfNeeded()
        for sheet in cache.values { sheet.update(highlight: value.highlighted, sourceOffset: value.sourceOffset, fold: value.fold, follow: value.follow) }
        if lastCommand != value.command.id {
            let initial = lastCommand == nil
            lastCommand = value.command.id
            if !initial, value.command.delta != 0 { turn(value.command.delta) }
        }
        followVoice()
    }
    private func reflowIfNeeded() {
        guard !rotating, !transitioning, let value = configuration, view.bounds.width > 80, view.bounds.height > 100 else { return }
        let font = BookPagination.font(for: traitCollection.preferredContentSizeCategory)
        let width = floor(view.bounds.width / CGFloat(value.pages))
        let inset = BookSheetController.insets(spread: value.pages == 2, gutter: value.gutter)
        let bodySize = CGSize(width: width - inset.left - inset.right,
                              height: view.bounds.height - inset.top - inset.bottom)
        let key = "\(value.sourceOffset)|\(value.pages)|\(bodySize)|\(font.pointSize)|\(value.reduceMotion)"
        guard signature != key || pagination?.text != value.text else { return }
        let anchor: Int
        if value.follow, let spoken = lastSpokenOffset { anchor = spoken - value.sourceOffset }
        else { anchor = (readingAnchor ?? value.position) - value.sourceOffset }
        signature = key; generation = UUID(); transitioning = false; pendingFollow = false
        pageCount = value.pages; reduced = value.reduceMotion
        isRTL = BookPagination.isRightToLeft(value.text)
        pagination = BookPagination(text: value.text, bodySize: bodySize, font: font)
        let next = UIPageViewController(transitionStyle: reduced ? .scroll : .pageCurl,
                                        navigationOrientation: .horizontal,
                                        options: reduced ? nil : [.spineLocation: NSNumber(value: pageCount == 2 ? UIPageViewController.SpineLocation.mid.rawValue : (isRTL ? UIPageViewController.SpineLocation.max.rawValue : UIPageViewController.SpineLocation.min.rawValue))])
        next.view.semanticContentAttribute = .forceLeftToRight
        next.isDoubleSided = !reduced && pageCount == 2
        next.dataSource = self; next.delegate = self
        cache.removeAll()
        currentPage = (pagination?.page(containing: max(0, anchor)) ?? 0) / step * step
        // A page-curl controller validates its leaf count as soon as it joins
        // a visible window. Never attach a transient, empty replacement.
        next.setViewControllers(visibleControllers(start: currentPage), direction: .forward, animated: false)
        if let pager {
            pager.dataSource = nil; pager.delegate = nil
            pager.willMove(toParent: nil); pager.view.removeFromSuperview(); pager.removeFromParent()
        }
        pager = next
        addChild(next); next.view.frame = view.bounds; next.view.backgroundColor = .clear
        view.addSubview(next.view); next.didMove(toParent: self)
        setNeedsUpdateOfSupportedInterfaceOrientations()
        publishPageInfo()
    }
    private func sheet(_ index: Int) -> BookSheetController {
        if let existing = cache[index] { return existing }
        let sheet = BookSheetController(index: index)
        if let pagination, let value = configuration {
            sheet.configure(pagination: pagination, title: value.title, count: reduced ? pageCount : 1,
                            spread: pageCount == 2, gutter: value.gutter, rtl: isRTL,
                            sourceOffset: value.sourceOffset, highlight: value.highlighted, fold: value.fold, follow: value.follow)
        }
        cache[index] = sheet
        return sheet
    }
    private func visibleControllers(start: Int) -> [UIViewController] {
        var indices = (0..<groupSize).map { start + $0 }
        if isRTL && groupSize > 1 { indices.reverse() }
        return indices.map { sheet($0) }
    }
    private func publishPageInfo() {
        guard let value = configuration, let pagination else { return }
        let page = currentPage, count = pagination.ranges.count, token = generation
        DispatchQueue.main.async { [weak self] in
            guard self?.generation == token else { return }
            value.onPageInfo(page, count)
        }
        cache = cache.filter { abs($0.key - page) <= 4 }
    }
    private func followVoice() {
        guard let value = configuration, value.follow, let pagination else { return }
        guard let absolute = value.highlighted?.location ?? followOffset else { return }
        followOffset = nil
        if rotating { followOffset = absolute; return }
        let offset = absolute - value.sourceOffset
        guard offset >= 0, offset <= value.text.utf16.count else { return }
        let target = pagination.page(containing: offset) / step * step
        guard target != currentPage else { return }
        if transitioning { followOffset = absolute; pendingFollow = true; return }
        show(target, animated: abs(target - currentPage) == step, userInitiated: false)
    }
    func turn(_ direction: Int) {
        guard !transitioning, !rotating, let pagination, let value = configuration else { return }
        let target = currentPage + (direction > 0 ? step : -step)
        guard target >= 0, target < pagination.ranges.count else { value.onBoundary(direction); return }
        show(target, animated: true, userInitiated: true)
    }
    private func show(_ target: Int, animated: Bool, userInitiated: Bool) {
        guard let pager else { return }
        let forward = target > currentPage
        transitioning = true
        let token = generation
        pager.setViewControllers(visibleControllers(start: target), direction: forward != isRTL ? .forward : .reverse,
                                 animated: animated && !reduced) { [weak self] finished in
            guard let self, self.generation == token else { return }
            self.transitioning = false
            if finished {
                self.currentPage = target
                if userInitiated { self.didBrowse() }
                self.publishPageInfo()
            }
            self.reflowIfNeeded()
            if userInitiated { self.pendingFollow = false }
            else if self.pendingFollow { self.pendingFollow = false; self.followVoice() }
        }
    }
    private func didBrowse() {
        guard let value = configuration, let pagination, pagination.ranges.indices.contains(currentPage) else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        let offset = value.sourceOffset + pagination.ranges[currentPage].location
        readingAnchor = offset
        value.onBrowse(offset)
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore controller: UIViewController) -> UIViewController? {
        neighbour(controller, delta: isRTL ? 1 : -1)
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter controller: UIViewController) -> UIViewController? {
        neighbour(controller, delta: isRTL ? -1 : 1)
    }
    private func neighbour(_ controller: UIViewController, delta: Int) -> UIViewController? {
        guard let sheet = controller as? BookSheetController, let pagination else { return nil }
        let index = sheet.index + delta * (reduced ? pageCount : 1)
        let paddedCount = (pagination.ranges.count + step - 1) / step * step
        guard index >= 0, index < paddedCount else { return nil }
        return self.sheet(index)
    }
    func pageViewControllerSupportedInterfaceOrientations(_ pageViewController: UIPageViewController) -> UIInterfaceOrientationMask { .allButUpsideDown }
    func pageViewController(_ pageViewController: UIPageViewController, spineLocationFor orientation: UIInterfaceOrientation) -> UIPageViewController.SpineLocation {
        // Keep the existing leaf count while UIKit rotates this controller.
        // The completed layout replaces it with the final single page or spread.
        return pageCount == 2 ? .mid : (isRTL ? .max : .min)
    }
    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        transitioning = true
    }
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard pageViewController === pager else { return }
        transitioning = false
        guard !rotating else { return }
        if completed, let page = pageViewController.viewControllers?.compactMap({ ($0 as? BookSheetController)?.index }).min() {
            currentPage = page / step * step
            didBrowse(); publishPageInfo()
        }
        reflowIfNeeded()
        // A manual turn takes priority over a queued auto-turn.
        pendingFollow = false
    }
}

private final class BookSheetController: UIViewController {
    let index: Int
    private var sheets: [BookPaperView] = []
    init(index: Int) { self.index = index; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func insets(spread: Bool, gutter: CGFloat, innerLeft: Bool = false) -> UIEdgeInsets {
        let inner = spread ? max(26, gutter / 2 + 18) : 28
        let outer: CGFloat = spread ? 26 : 28
        return UIEdgeInsets(top: 52, left: innerLeft ? inner : outer, bottom: 40, right: innerLeft ? outer : inner)
    }
    override func loadView() { view = UIView(); view.backgroundColor = BookPaperView.paper }
    func configure(pagination: BookPagination, title: String, count: Int, spread: Bool, gutter: CGFloat,
                   rtl: Bool, sourceOffset: Int, highlight: NSRange?, fold: Double, follow: Bool) {
        loadViewIfNeeded()
        var indices = (index..<index + count).map { $0 }
        if rtl { indices.reverse() }
        for number in indices {
            let paper = BookPaperView()
            let range = pagination.ranges.indices.contains(number) ? pagination.ranges[number] : NSRange(location: pagination.text.utf16.count, length: 0)
            paper.configure(text: (pagination.text as NSString).substring(with: range), range: range,
                            font: pagination.font, title: title, page: number < pagination.ranges.count ? number + 1 : nil,
                            inset: Self.insets(spread: spread, gutter: gutter, innerLeft: number % 2 == (rtl ? 0 : 1)), innerLeft: number % 2 == (rtl ? 0 : 1))
            sheets.append(paper); view.addSubview(paper)
        }
        update(highlight: highlight, sourceOffset: sourceOffset, fold: fold, follow: follow)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        for (offset, sheet) in sheets.enumerated() {
            sheet.frame = CGRect(x: CGFloat(offset) * view.bounds.width / CGFloat(sheets.count), y: 0,
                                 width: view.bounds.width / CGFloat(sheets.count), height: view.bounds.height)
        }
    }
    func update(highlight: NSRange?, sourceOffset: Int, fold: Double, follow: Bool) {
        for sheet in sheets { sheet.update(highlight: highlight, sourceOffset: sourceOffset, fold: fold, follow: follow) }
    }
}

private final class BookPaperView: UIView {
    static let paper = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.105, green: 0.10, blue: 0.125, alpha: 1) : UIColor(red: 0.993, green: 0.985, blue: 0.965, alpha: 1) }
    private let textView = UITextView(usingTextLayoutManager: false)
    private let heading = UILabel()
    private let footer = UILabel()
    private let spine = CAGradientLayer()
    private var sourceRange = NSRange(location: 0, length: 0)
    private var previous: NSRange?
    private var inset = UIEdgeInsets.zero
    private var innerLeft = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Self.paper
        textView.isEditable = false; textView.isSelectable = true
        textView.backgroundColor = .clear; textView.textContainerInset = .zero
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainer.lineFragmentPadding = 0
        textView.accessibilityLabel = "Page text"
        heading.font = .systemFont(ofSize: 10, weight: .medium); heading.textColor = .secondaryLabel
        heading.textAlignment = .center; heading.adjustsFontSizeToFitWidth = true; heading.minimumScaleFactor = 0.8
        footer.font = .systemFont(ofSize: 11, weight: .regular); footer.textColor = .secondaryLabel; footer.textAlignment = .center
        addSubview(heading); addSubview(textView); addSubview(footer)
        spine.startPoint = CGPoint(x: 0, y: 0.5); spine.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(spine)
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(text: String, range: NSRange, font: UIFont, title: String, page: Int?, inset: UIEdgeInsets, innerLeft: Bool) {
        self.sourceRange = range; self.inset = inset; self.innerLeft = innerLeft
        textView.attributedText = BookPagination.attributed(text, font: font)
        heading.text = title.uppercased(); footer.text = page.map(String.init) ?? ""
        footer.accessibilityLabel = page.map { "Page \($0) in this section" }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        heading.frame = CGRect(x: inset.left, y: 18, width: bounds.width - inset.left - inset.right, height: 16)
        textView.frame = bounds.inset(by: inset)
        let source = textView.text as NSString
        var end = source.length
        while end > 0, let scalar = UnicodeScalar(source.character(at: end - 1)), CharacterSet.whitespacesAndNewlines.contains(scalar) { end -= 1 }
        let glyphs = textView.layoutManager.glyphRange(forCharacterRange: NSRange(location: 0, length: end), actualCharacterRange: nil)
        let used = textView.layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
        textView.isScrollEnabled = used.maxY > textView.bounds.height + 2
        footer.frame = CGRect(x: 0, y: bounds.height - 29, width: bounds.width, height: 16)
        spine.frame = CGRect(x: innerLeft ? 0 : bounds.width - 25, y: 0, width: 25, height: bounds.height)
    }
    func update(highlight: NSRange?, sourceOffset: Int, fold: Double, follow: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let shade = UIColor.black.withAlphaComponent(0.025 + fold * 0.13).cgColor
        spine.colors = innerLeft ? [shade, UIColor.clear.cgColor] : [UIColor.clear.cgColor, shade]
        CATransaction.commit()
        let local = highlight.flatMap { word -> NSRange? in
            let page = NSRange(location: sourceOffset + sourceRange.location, length: sourceRange.length)
            let match = NSIntersectionRange(word, page)
            return match.length > 0 ? NSRange(location: match.location - page.location, length: match.length) : nil
        }
        guard local != previous else { return }
        if let previous, NSMaxRange(previous) <= textView.textStorage.length {
            textView.textStorage.removeAttribute(.backgroundColor, range: previous)
        }
        if let local, NSMaxRange(local) <= textView.textStorage.length {
            textView.textStorage.addAttribute(.backgroundColor, value: UIColor.systemOrange.withAlphaComponent(0.25), range: local)
            if textView.isScrollEnabled && follow { textView.scrollRangeToVisible(local) }
        }
        previous = local
    }
}
