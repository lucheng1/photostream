import Foundation
import PhotoStreamShared

/// Builds year/month timeline buckets for newest-first asset lists.
enum TimelineBuilder {
    static func build(dates: [Date?]) -> TimelineResponse {
        let calendar = Calendar.current
        var buckets: [TimelineBucket] = []
        var years: [TimelineYear] = []

        var currentYear: Int?
        var currentMonth: Int?
        var bucketStart = 0
        var bucketCount = 0
        var yearStart = 0
        var yearCount = 0

        func flushBucket() {
            guard let y = currentYear, let m = currentMonth, bucketCount > 0 else { return }
            buckets.append(TimelineBucket(year: y, month: m, startIndex: bucketStart, count: bucketCount))
        }
        func flushYear() {
            guard let y = currentYear, yearCount > 0 else { return }
            years.append(TimelineYear(year: y, startIndex: yearStart, count: yearCount))
        }

        for (index, date) in dates.enumerated() {
            let y: Int
            let m: Int
            if let date {
                y = calendar.component(.year, from: date)
                m = calendar.component(.month, from: date)
            } else {
                y = 0
                m = 0
            }

            if currentYear == nil {
                currentYear = y
                currentMonth = m
                bucketStart = index
                yearStart = index
            }

            if y != currentYear {
                flushBucket()
                flushYear()
                currentYear = y
                currentMonth = m
                bucketStart = index
                bucketCount = 0
                yearStart = index
                yearCount = 0
            } else if m != currentMonth {
                flushBucket()
                currentMonth = m
                bucketStart = index
                bucketCount = 0
            }

            bucketCount += 1
            yearCount += 1
        }
        flushBucket()
        flushYear()

        return TimelineResponse(buckets: buckets, years: years, totalCount: dates.count)
    }
}
