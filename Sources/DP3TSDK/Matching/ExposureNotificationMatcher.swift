/*
 * Created by Ubique Innovation AG
 * https://www.ubique.ch
 * Copyright (c) 2020. All rights reserved.
 */

import ExposureNotification
import Foundation
import ZIPFoundation

class ExposureNotificationMatcher: Matcher {
    weak var delegate: MatcherDelegate?

    private let manager: ENManager

    private let exposureDayStorage: ExposureDayStorage

    private let log = Logger(ExposureNotificationMatcher.self, category: "matcher")

    private var localURLs: [Date: [URL]] = [:]

    init(manager: ENManager, exposureDayStorage: ExposureDayStorage) {
        self.manager = manager
        self.exposureDayStorage = exposureDayStorage
    }

    func receivedNewKnownCaseData(_ data: Data, keyDate: Date) throws {
        log.trace()

        if let archive = Archive(data: data, accessMode: .read) {
            log.debug("unarchived archive")
            for entry in archive {
                let localURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                    .appendingPathComponent(UUID().uuidString).appendingPathComponent(entry.path)

                _ = try archive.extract(entry, to: localURL)

                log.debug("found %@ item in archive", entry.path)
                localURLs[keyDate, default: []].append(localURL)
            }
        }
    }

    func finalizeMatchingSession() throws {
        log.trace()
        guard localURLs.isEmpty == false else { return }

        for (day, urls) in localURLs {
            log.info("calling detectExposures for day %@", day.description)
            let semaphore = DispatchSemaphore(value: 0)
            var exposureSummary: ENExposureDetectionSummary?
            var exposureDetectionError: Error?
            let configuration: ENExposureConfiguration = .configuration()
            manager.detectExposures(configuration: configuration, diagnosisKeyURLs: urls) { summary, error in
                exposureSummary = summary
                exposureDetectionError = error
                semaphore.signal()
            }
            semaphore.wait()

            if let error = exposureDetectionError {
                log.error("exposureNotificationError %@", error.localizedDescription)
                throw DP3TTracingError.exposureNotificationError(error: error)
            }

            try urls.forEach(deleteDiagnosisKeyFile(at:))

            if let summary = exposureSummary {
                log.info("reiceived exposureSummary: %@", summary.debugDescription)
            }

            if let summary = exposureSummary,
                summary.attenuationDurations.count > 0,
                Double(truncating: summary.attenuationDurations[0]) > 15 * TimeInterval.minute {
                log.info("exposureSummary meets requiremnts")
                let exposedDate = Date(timeIntervalSinceNow: TimeInterval(summary.daysSinceLastExposure) * TimeInterval.day * (-1))
                let day: ExposureDay = ExposureDay(identifier: UUID(), exposedDate: exposedDate, reportDate: Date(), isDeleted: false)
                exposureDayStorage.add(day)
                delegate?.didFindMatch()
            } else {
                log.info("exposureSummary does not meet requirements")
            }
        }
        localURLs.removeAll()
    }

    func deleteDiagnosisKeyFile(at localURL: URL) throws {
        log.trace()
        try FileManager.default.removeItem(at: localURL)
    }
}

extension ENExposureConfiguration {
    static func configuration(parameters: DP3TParameters = Default.shared.parameters) -> ENExposureConfiguration {
        let configuration = ENExposureConfiguration()
        configuration.minimumRiskScore = 0
        configuration.attenuationLevelValues = [1, 2, 3, 4, 5, 6, 7, 8]
        configuration.attenuationWeight = 50
        configuration.daysSinceLastExposureLevelValues = [1, 2, 3, 4, 5, 6, 7, 8]
        configuration.daysSinceLastExposureWeight = 50
        configuration.durationLevelValues = [1, 2, 3, 4, 5, 6, 7, 8]
        configuration.durationWeight = 50
        configuration.transmissionRiskLevelValues = [1, 2, 3, 4, 5, 6, 7, 8]
        configuration.transmissionRiskWeight = 50
        configuration.metadata = ["attenuationDurationThresholds": [parameters.contactMatching.attenuationThresholdLow,
                                                                    parameters.contactMatching.attenuationThresholdHigh]]
        return configuration
    }
}
