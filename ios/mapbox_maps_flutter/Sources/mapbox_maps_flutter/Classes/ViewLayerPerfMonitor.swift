import UIKit
import QuartzCore

struct AnnotationTimingBreakdown {
    let id: String
    let factoryMs: Double
    let sizeMs: Double
    let addToMapMs: Double
    var totalMs: Double { factoryMs + sizeMs + addToMapMs }
}

class ViewLayerPerfMonitor {
    static let shared = ViewLayerPerfMonitor()

    // MARK: - Operation context tracking

    /// Set by instrumented code to indicate the current operation in progress.
    /// Read by the frame drop detector to correlate jank to a root cause.
    private(set) var currentOperation: String = "idle"
    private var operationStartTime: CFTimeInterval = 0

    // MARK: - Annotation count (updated externally)

    var currentAnnotationCount: Int = 0

    // MARK: - Update cycle tracking

    private var cycleStartTime: CFTimeInterval = 0
    private var cycleMainThreadStart: CFTimeInterval = 0
    private var currentCycleId: UInt64 = 0

    // MARK: - Frame drop detection (CADisplayLink)

    private var displayLink: CADisplayLink?
    private var lastFrameTimestamp: CFTimeInterval = 0

    // MARK: - Aggregate stats (periodic 5s timer)

    private var statsTimer: Timer?
    private var periodCreates: Int = 0
    private var periodRemoves: Int = 0
    private var periodDroppedFrames: Int = 0
    var periodChurnCount: Int = 0
    private var cumulativeFactoryMs: Double = 0
    private var cumulativeSizeMs: Double = 0
    private var cumulativeAddToMapMs: Double = 0
    private var cumulativeQueryMs: Double = 0

    // MARK: - Slow create threshold (half a frame budget at 60fps)

    private let slowCreateThresholdMs: Double = 8.0

    private init() {}

    // MARK: - Start / Stop

    func startMonitoring() {
        guard displayLink == nil else { return }

        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired(_:)))
        displayLink?.add(to: .main, forMode: .common)

        statsTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.logPeriodicStats()
        }

        NSLog("[ViewLayerPerf] MONITOR_START")
    }

    func stopMonitoring() {
        displayLink?.invalidate()
        displayLink = nil
        statsTimer?.invalidate()
        statsTimer = nil

        NSLog("[ViewLayerPerf] MONITOR_STOP")
    }

    // MARK: - Operation context

    func beginOperation(_ name: String) {
        currentOperation = name
        operationStartTime = CACurrentMediaTime()
    }

    func endOperation(_ name: String) {
        currentOperation = "idle"
        operationStartTime = 0
    }

    // MARK: - Update cycle

    func beginUpdateCycle(trigger: String, zoom: Double, layerCount: Int) -> UInt64 {
        currentCycleId += 1
        cycleStartTime = CACurrentMediaTime()
        cycleMainThreadStart = CACurrentMediaTime()
        return currentCycleId
    }

    func endUpdateCycle(cycleId: UInt64, layer: String, queryMs: Double, created: Int, removed: Int) {
        let totalMs = (CACurrentMediaTime() - cycleStartTime) * 1000
        let mainThreadMs = (CACurrentMediaTime() - cycleMainThreadStart) * 1000

        NSLog("[ViewLayerPerf] UPDATE_CYCLE_END cycle=%llu layer=%@ totalMs=%.1f queryMs=%.1f mainThreadMs=%.1f created=%d removed=%d",
              cycleId, layer, totalMs, queryMs, mainThreadMs, created, removed)
    }

    // MARK: - Annotation creation recording

    func recordAnnotationCreation(_ breakdown: AnnotationTimingBreakdown) {
        periodCreates += 1
        cumulativeFactoryMs += breakdown.factoryMs
        cumulativeSizeMs += breakdown.sizeMs
        cumulativeAddToMapMs += breakdown.addToMapMs

        if breakdown.totalMs > slowCreateThresholdMs {
            NSLog("[ViewLayerPerf] SLOW_CREATE id=%@ total=%.1f factory=%.1f size=%.1f addToMap=%.1f",
                  breakdown.id, breakdown.totalMs, breakdown.factoryMs, breakdown.sizeMs, breakdown.addToMapMs)
        }
    }

    // MARK: - Annotation removal recording

    func recordAnnotationRemoval(id: String, durationMs: Double, remaining: Int) {
        periodRemoves += 1
    }

    // MARK: - Query timing

    func recordQueryTime(_ ms: Double) {
        cumulativeQueryMs += ms
    }

    // MARK: - CADisplayLink callback

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastFrameTimestamp > 0 {
            let frameDuration = (now - lastFrameTimestamp) * 1000  // ms
            if frameDuration > 20 {
                periodDroppedFrames += 1
                // Only log severe jank (>50ms = 3+ dropped frames) to reduce noise
                if frameDuration > 50 {
                    NSLog("[ViewLayerPerf] JANK frameDuration=%.1f during=%@ annotations=%d",
                          frameDuration, currentOperation, currentAnnotationCount)
                }
            }
        }
        lastFrameTimestamp = now
    }

    // MARK: - Periodic stats

    private func logPeriodicStats() {
        // Only log when something happened in this period
        if periodDroppedFrames > 0 || periodCreates > 0 || periodRemoves > 0 {
            NSLog("[ViewLayerPerf] STATS droppedFrames=%d creates=%d removes=%d churn=%d annotations=%d",
                  periodDroppedFrames, periodCreates, periodRemoves, periodChurnCount, currentAnnotationCount)
        }

        // Reset period counters
        periodCreates = 0
        periodRemoves = 0
        periodDroppedFrames = 0
        periodChurnCount = 0
    }
}
