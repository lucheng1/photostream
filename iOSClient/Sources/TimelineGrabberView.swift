import UIKit

protocol TimelineGrabberDelegate: AnyObject {
    func timelineGrabberDidBeginScrub(_ grabber: TimelineGrabberView)
    func timelineGrabber(_ grabber: TimelineGrabberView, didScrubTo bucket: TimelineBucket, progress: CGFloat)
    func timelineGrabber(_ grabber: TimelineGrabberView, didPauseAt bucket: TimelineBucket)
    func timelineGrabber(_ grabber: TimelineGrabberView, didEndScrubAt bucket: TimelineBucket)
}

/// Amazon Photos–style right-edge timeline grabber with year rail + month bubble.
final class TimelineGrabberView: UIView {
    weak var delegate: TimelineGrabberDelegate?

    private var buckets: [TimelineBucket] = []
    private var years: [TimelineYear] = []
    private var totalCount: Int = 0

    private let handle = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialLight))
    private let handleIcon = UIImageView()
    private let monthBubble = UILabel()
    private let yearRail = UIView()
    private var yearLabels: [UILabel] = []
    private var handleCenterY: NSLayoutConstraint!

    private var isExpanded = false
    private var isDragging = false
    private var currentBucketIndex = 0
    private var pauseWorkItem: DispatchWorkItem?
    private var hideWorkItem: DispatchWorkItem?

    private let handleSize: CGFloat = 36

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        alpha = 0
        clipsToBounds = false

        yearRail.alpha = 0
        yearRail.isUserInteractionEnabled = false
        yearRail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(yearRail)

        monthBubble.font = .systemFont(ofSize: 14, weight: .semibold)
        monthBubble.textColor = .label
        monthBubble.backgroundColor = UIColor.white.withAlphaComponent(0.95)
        monthBubble.textAlignment = .center
        monthBubble.layer.cornerRadius = 14
        monthBubble.clipsToBounds = true
        monthBubble.alpha = 0
        monthBubble.translatesAutoresizingMaskIntoConstraints = false
        addSubview(monthBubble)

        handle.layer.cornerRadius = handleSize / 2
        handle.clipsToBounds = true
        handle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(handle)

        handleIcon.image = UIImage(systemName: "chevron.up.chevron.down")
        handleIcon.tintColor = .label
        handleIcon.contentMode = .scaleAspectFit
        handleIcon.translatesAutoresizingMaskIntoConstraints = false
        handle.contentView.addSubview(handleIcon)

        handleCenterY = handle.centerYAnchor.constraint(equalTo: topAnchor, constant: 80)

        NSLayoutConstraint.activate([
            handle.widthAnchor.constraint(equalToConstant: handleSize),
            handle.heightAnchor.constraint(equalToConstant: handleSize),
            handle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            handleCenterY,

            handleIcon.centerXAnchor.constraint(equalTo: handle.contentView.centerXAnchor),
            handleIcon.centerYAnchor.constraint(equalTo: handle.contentView.centerYAnchor),
            handleIcon.widthAnchor.constraint(equalToConstant: 16),
            handleIcon.heightAnchor.constraint(equalToConstant: 16),

            monthBubble.trailingAnchor.constraint(equalTo: handle.leadingAnchor, constant: -8),
            monthBubble.centerYAnchor.constraint(equalTo: handle.centerYAnchor),
            monthBubble.heightAnchor.constraint(equalToConstant: 28),
            monthBubble.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),

            yearRail.trailingAnchor.constraint(equalTo: handle.leadingAnchor, constant: -8),
            yearRail.topAnchor.constraint(equalTo: topAnchor),
            yearRail.bottomAnchor.constraint(equalTo: bottomAnchor),
            yearRail.widthAnchor.constraint(equalToConstant: 56),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        handle.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        handle.addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { nil }

    func configure(timeline: TimelineResponse) {
        buckets = timeline.buckets
        years = timeline.years
        totalCount = max(timeline.totalCount, 1)
        rebuildYearLabels()
        if !buckets.isEmpty {
            currentBucketIndex = bucketIndex(forProgress: 0.5)
            updateMonthBubble()
            centerHandle(animated: false)
        }
    }

    func showGrabber(animated: Bool = true) {
        hideWorkItem?.cancel()
        // Idle grabber always appears mid-screen; scrubbing moves it from there.
        if !isDragging {
            centerHandle(animated: false)
            if !buckets.isEmpty {
                currentBucketIndex = bucketIndex(forProgress: 0.5)
                updateMonthBubble()
            }
        }
        let work = { self.alpha = 1 }
        if animated {
            UIView.animate(withDuration: 0.2, animations: work)
        } else {
            work()
        }
    }

    func scheduleHide(after delay: TimeInterval = 1.2) {
        guard !isDragging else { return }
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isDragging else { return }
            self.collapse(animated: true)
            UIView.animate(withDuration: 0.25) { self.alpha = 0 }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func centerHandle(animated: Bool = false) {
        layoutHandle(forProgress: 0.5, animated: animated)
    }

    private func rebuildYearLabels() {
        yearLabels.forEach { $0.removeFromSuperview() }
        yearLabels.removeAll()
        guard totalCount > 0 else { return }
        for year in years {
            let label = UILabel()
            label.text = year.year <= 1 ? "No Date" : "\(year.year)"
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            label.backgroundColor = UIColor.secondarySystemFill.withAlphaComponent(0.9)
            label.layer.cornerRadius = 9
            label.clipsToBounds = true
            label.translatesAutoresizingMaskIntoConstraints = false
            yearRail.addSubview(label)
            yearLabels.append(label)

            let mid = year.startIndex + max(year.count / 2, 0)
            let progress = CGFloat(mid) / CGFloat(max(totalCount - 1, 1))
            label.layer.setValue(progress, forKey: "timelineProgress")
            NSLayoutConstraint.activate([
                label.trailingAnchor.constraint(equalTo: yearRail.trailingAnchor),
                label.widthAnchor.constraint(equalToConstant: 52),
                label.heightAnchor.constraint(equalToConstant: 18),
            ])
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let track = trackRange()
        for label in yearLabels {
            let progress = (label.layer.value(forKey: "timelineProgress") as? CGFloat) ?? 0
            let y = track.top + progress * track.height
            label.center = CGPoint(x: yearRail.bounds.midX, y: yearRail.convert(CGPoint(x: 0, y: y), from: self).y)
        }
    }

    private func trackRange() -> (top: CGFloat, bottom: CGFloat, height: CGFloat) {
        let top = safeAreaInsets.top + 24
        let bottom = bounds.height - safeAreaInsets.bottom - 24
        return (top, bottom, max(bottom - top, 1))
    }

    private func expand(animated: Bool) {
        isExpanded = true
        let changes = {
            self.yearRail.alpha = 1
            self.monthBubble.alpha = 1
        }
        if animated {
            UIView.animate(withDuration: 0.2, animations: changes)
        } else {
            changes()
        }
    }

    private func collapse(animated: Bool) {
        isExpanded = false
        let changes = {
            self.yearRail.alpha = 0
            self.monthBubble.alpha = 0
        }
        if animated {
            UIView.animate(withDuration: 0.2, animations: changes)
        } else {
            changes()
        }
    }

    @objc private func handleTap() {
        showGrabber()
        expand(animated: true)
        scheduleHide(after: 2.0)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let track = trackRange()

        switch gesture.state {
        case .began:
            hideWorkItem?.cancel()
            isDragging = true
            showGrabber(animated: true)
            expand(animated: true)
            delegate?.timelineGrabberDidBeginScrub(self)

        case .changed:
            let location = gesture.location(in: self)
            let y = min(max(location.y, track.top), track.bottom)
            let progress = (y - track.top) / track.height
            layoutHandle(forProgress: progress, animated: false)
            let idx = bucketIndex(forProgress: progress)
            if idx != currentBucketIndex {
                currentBucketIndex = idx
                updateMonthBubble()
                pauseWorkItem?.cancel()
            }
            if let bucket = currentBucket() {
                delegate?.timelineGrabber(self, didScrubTo: bucket, progress: progress)
            }
            pauseWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isDragging, let bucket = self.currentBucket() else { return }
                self.delegate?.timelineGrabber(self, didPauseAt: bucket)
            }
            pauseWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)

        case .ended, .cancelled:
            isDragging = false
            pauseWorkItem?.cancel()
            if let bucket = currentBucket() {
                delegate?.timelineGrabber(self, didEndScrubAt: bucket)
            }
            scheduleHide(after: 1.0)

        default:
            break
        }
    }

    private func layoutHandle(forProgress progress: CGFloat, animated: Bool) {
        let track = trackRange()
        let y = track.top + min(max(progress, 0), 1) * track.height
        let apply = { self.handleCenterY.constant = y }
        if animated {
            UIView.animate(withDuration: 0.15) {
                apply()
                self.layoutIfNeeded()
            }
        } else {
            apply()
        }
    }

    private func bucketIndex(forProgress progress: CGFloat) -> Int {
        guard !buckets.isEmpty, totalCount > 0 else { return 0 }
        let target = Int(round(progress * CGFloat(max(totalCount - 1, 0))))
        var best = 0
        for (i, bucket) in buckets.enumerated() {
            if bucket.startIndex <= target {
                best = i
            } else {
                break
            }
        }
        return best
    }

    private func currentBucket() -> TimelineBucket? {
        guard buckets.indices.contains(currentBucketIndex) else { return nil }
        return buckets[currentBucketIndex]
    }

    private func updateMonthBubble() {
        guard let bucket = currentBucket() else {
            monthBubble.text = "—"
            return
        }
        if bucket.year <= 1 {
            monthBubble.text = "  No Date  "
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM yyyy"
            var comps = DateComponents()
            comps.year = bucket.year
            comps.month = bucket.month
            comps.day = 1
            let date = Calendar.current.date(from: comps) ?? Date()
            monthBubble.text = "  \(formatter.string(from: date))  "
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if alpha < 0.05 { return false }
        let handleRect = handle.frame.insetBy(dx: -16, dy: -16)
        if isExpanded {
            return bounds.contains(point) || handleRect.contains(point)
        }
        return handleRect.contains(point)
    }
}
