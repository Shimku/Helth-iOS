#if DEBUG
import HealthKit
import CoreLocation

/// Fills a simulator with a month of data shaped like an iPhone plus Apple Watch: every path
/// the exporter and importer take (series, correlations, routes, multisport, legacy totals,
/// heartbeat series, all metadata value kinds). Deterministic, so `partial` lays down exact
/// copies of the first days on the target to check that duplicates are skipped.
enum Seeder {
    struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    }

    static let base = Date(timeIntervalSince1970: 1_788_220_800) // 2026-09-01 00:00 UTC
    static let watch = HKDevice(name: "Apple Watch", manufacturer: "Apple Inc.", model: "Watch", hardwareVersion: "Watch7,3",
                                firmwareVersion: nil, softwareVersion: "26.0", localIdentifier: nil, udiDeviceIdentifier: nil)
    static let phone = HKDevice(name: "iPhone", manufacturer: "Apple Inc.", model: "iPhone", hardwareVersion: "iPhone17,3",
                                firmwareVersion: nil, softwareVersion: "26.0", localIdentifier: nil, udiDeviceIdentifier: nil)

    static func q(_ id: HKQuantityTypeIdentifier) -> HKQuantityType { HKObjectType.quantityType(forIdentifier: id)! }
    static func c(_ id: HKCategoryTypeIdentifier) -> HKCategoryType { HKObjectType.categoryType(forIdentifier: id)! }
    static func at(_ day: Int, _ hours: Double) -> Date { base.addingTimeInterval(Double(day) * 86400 + hours * 3600) }
    static let tz = [HKMetadataKeyTimeZone: "Europe/Helsinki"]

    /// About 220,000 records: a year of heart rate every 5 minutes and four months of
    /// per-minute active energy, to time export and import at a realistic size.
    static func bulk() async throws {
        let hr = q(.heartRate), energy = q(.activeEnergyBurned)
        try await HealthAccess.request(share: [hr, energy], read: [hr, energy])
        var rng = RNG(state: 7)
        let start = base.addingTimeInterval(-365 * 86400)
        let bpm = HKUnit.count().unitDivided(by: .minute())
        var batch: [HKObject] = []
        for i in 0..<(365 * 288) {
            let t = start.addingTimeInterval(Double(i) * 300)
            batch.append(HKQuantitySample(type: hr, quantity: HKQuantity(unit: bpm, doubleValue: rng.range(50, 120).rounded()), start: t, end: t, device: watch,
                                          metadata: [HKMetadataKeyHeartRateMotionContext: NSNumber(value: 1)]))
            if batch.count == 10000 { try await Health.store.save(batch); batch = [] }
        }
        for day in 0..<120 {
            for minute in 0..<(16 * 60) {
                let t = start.addingTimeInterval(Double(day) * 86400 + 7 * 3600 + Double(minute) * 60)
                batch.append(HKQuantitySample(type: energy, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: rng.range(0.5, 6)), start: t, end: t.addingTimeInterval(60), device: watch, metadata: nil))
                if batch.count == 10000 { try await Health.store.save(batch); batch = [] }
            }
        }
        if !batch.isEmpty { try await Health.store.save(batch) }
    }

    static func seed(partial: Bool) async throws {
        var share = Set<HKSampleType>(HealthAccess.writable(Set(Catalog.quantityTypes.map(\.0) as [HKSampleType] + Catalog.categoryTypes)).ok)
        share.formUnion([HKObjectType.workoutType(), HKSeriesType.workoutRoute(), HKSeriesType.heartbeat()])
        if #available(iOS 18.0, *) { share.insert(HKObjectType.stateOfMindType()) }
        try await HealthAccess.request(share: share, read: Set(share))

        let days = partial ? 3 : 30
        var rng = RNG(state: 42)
        var batch: [HKObject] = []
        func flush() async throws { if !batch.isEmpty { try await Health.store.save(batch); batch = [] } }

        for day in 0..<days {
            // Heart rate every 10 minutes from the Watch, a few with custom metadata of each kind.
            for slot in 0..<144 {
                let t = at(day, Double(slot) / 6)
                var meta: [String: Any] = tz
                meta[HKMetadataKeyHeartRateMotionContext] = NSNumber(value: slot % 3 == 0 ? 1 : 2)
                if slot == 7 {
                    meta["Note"] = "custom string"
                    meta["Custom integer"] = NSNumber(value: 7)
                    meta["Custom double"] = NSNumber(value: 0.125)
                    meta["Custom date"] = t
                    meta["Custom length"] = HKQuantity(unit: .meter(), doubleValue: 12.5)
                }
                batch.append(HKQuantitySample(type: q(.heartRate), quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: rng.range(52, 118).rounded()),
                                              start: t, end: t, device: watch, metadata: meta))
            }
            // Steps, distance and energy through the day.
            for hour in 8..<22 {
                let s = at(day, Double(hour)), e = at(day, Double(hour) + 1)
                batch.append(HKQuantitySample(type: q(.stepCount), quantity: HKQuantity(unit: .count(), doubleValue: rng.range(100, 1500).rounded()), start: s, end: e, device: phone, metadata: tz))
                batch.append(HKQuantitySample(type: q(.distanceWalkingRunning), quantity: HKQuantity(unit: .meter(), doubleValue: rng.range(80, 1100)), start: s, end: e, device: phone, metadata: nil))
                batch.append(HKQuantitySample(type: q(.basalEnergyBurned), quantity: HKQuantity(unit: .kilocalorie(), doubleValue: rng.range(55, 70)), start: s, end: e, device: watch, metadata: nil))
                for quarter in 0..<4 {
                    let qs = s.addingTimeInterval(Double(quarter) * 900)
                    batch.append(HKQuantitySample(type: q(.activeEnergyBurned), quantity: HKQuantity(unit: .kilocalorie(), doubleValue: rng.range(1, 40)), start: qs, end: qs.addingTimeInterval(900), device: watch, metadata: nil))
                }
            }
            // Sleep stages.
            var t = at(day, -1.5)
            batch.append(HKCategorySample(type: c(.sleepAnalysis), value: HKCategoryValueSleepAnalysis.inBed.rawValue, start: t, end: t.addingTimeInterval(8 * 3600), device: watch, metadata: tz))
            for stage in [HKCategoryValueSleepAnalysis.asleepCore, .asleepDeep, .asleepREM, .awake, .asleepCore, .asleepREM, .asleepCore] {
                let len = rng.range(0.4, 1.6) * 3600
                batch.append(HKCategorySample(type: c(.sleepAnalysis), value: stage.rawValue, start: t, end: t.addingTimeInterval(len), device: watch, metadata: nil))
                t = t.addingTimeInterval(len)
            }
            // Daily HRV and oxygen.
            let h = at(day, 3)
            batch.append(HKQuantitySample(type: q(.heartRateVariabilitySDNN), quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: rng.range(25, 80)), start: h, end: h.addingTimeInterval(60), device: watch, metadata: nil))
            batch.append(HKQuantitySample(type: q(.oxygenSaturation), quantity: HKQuantity(unit: .percent(), doubleValue: rng.range(0.94, 0.99)), start: h, end: h, device: watch, metadata: nil))
            try await flush()
        }
        if partial { return }

        // Steps from the Watch as one series per day, the way watchOS stores them.
        for day in 0..<days {
            let b = HKQuantitySeriesSampleBuilder(healthStore: Health.store, quantityType: q(.stepCount), startDate: at(day, 9), device: watch)
            for i in 0..<20 {
                let s = at(day, 9 + Double(i) * 0.05)
                try b.insert(HKQuantity(unit: .count(), doubleValue: Double(10 + i)), for: DateInterval(start: s, end: s.addingTimeInterval(150)))
            }
            _ = try await b.finishSeries(metadata: tz, endDate: at(day, 10))
        }

        // Manual entries and required metadata.
        for week in 0..<5 {
            let t = at(week * 7, 7.5)
            batch.append(HKQuantitySample(type: q(.bodyMass), quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: 61.2 + Double(week) * 0.1), start: t, end: t, device: nil, metadata: [HKMetadataKeyWasUserEntered: true]))
        }
        for d in 3..<8 {
            batch.append(HKCategorySample(type: c(.menstrualFlow), value: HKCategoryValueMenstrualFlow.medium.rawValue, start: at(d, 0), end: at(d + 1, 0), device: nil,
                                          metadata: [HKMetadataKeyMenstrualCycleStart: d == 3, HKMetadataKeyWasUserEntered: true]))
        }
        batch.append(HKCategorySample(type: c(.sexualActivity), value: HKCategoryValue.notApplicable.rawValue, start: at(10, 22), end: at(10, 22), device: nil,
                                      metadata: [HKMetadataKeySexualActivityProtectionUsed: true]))
        batch.append(HKQuantitySample(type: q(.bloodGlucose), quantity: HKQuantity(unit: HKUnit(from: "mg/dL"), doubleValue: 94), start: at(11, 8), end: at(11, 8), device: nil,
                                      metadata: [HKMetadataKeyBloodGlucoseMealTime: NSNumber(value: HKBloodGlucoseMealTime.preprandial.rawValue)]))
        batch.append(HKQuantitySample(type: q(.insulinDelivery), quantity: HKQuantity(unit: .internationalUnit(), doubleValue: 4), start: at(11, 8), end: at(11, 8), device: nil,
                                      metadata: [HKMetadataKeyInsulinDeliveryReason: NSNumber(value: HKInsulinDeliveryReason.bolus.rawValue)]))
        for i in 0..<10 {
            let s = at(i * 3, 12)
            batch.append(HKCategorySample(type: c(.mindfulSession), value: HKCategoryValue.notApplicable.rawValue, start: s, end: s.addingTimeInterval(300), device: watch, metadata: nil))
        }
        // Blood pressure and food come as correlations.
        for i in 0..<10 {
            let t = at(i * 3, 8)
            let sys = HKQuantitySample(type: q(.bloodPressureSystolic), quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: 112 + Double(i)), start: t, end: t)
            let dia = HKQuantitySample(type: q(.bloodPressureDiastolic), quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: 72 + Double(i)), start: t, end: t)
            batch.append(HKCorrelation(type: HKObjectType.correlationType(forIdentifier: .bloodPressure)!, start: t, end: t, objects: [sys, dia], device: nil, metadata: [HKMetadataKeyWasUserEntered: true]))
        }
        for i in 0..<3 {
            let t = at(i * 5, 13)
            let parts: Set<HKSample> = [
                HKQuantitySample(type: q(.dietaryEnergyConsumed), quantity: HKQuantity(unit: .kilocalorie(), doubleValue: 640), start: t, end: t),
                HKQuantitySample(type: q(.dietaryProtein), quantity: HKQuantity(unit: .gram(), doubleValue: 31), start: t, end: t),
                HKQuantitySample(type: q(.dietaryCarbohydrates), quantity: HKQuantity(unit: .gram(), doubleValue: 70), start: t, end: t),
            ]
            batch.append(HKCorrelation(type: HKObjectType.correlationType(forIdentifier: .food)!, start: t, end: t, objects: parts, metadata: [HKMetadataKeyFoodType: "Lunch"]))
        }
        if #available(iOS 18.0, *) {
            for i in 0..<5 {
                batch.append(HKStateOfMind(date: at(i * 4, 20), kind: i % 2 == 0 ? .dailyMood : .momentaryEmotion, valence: -0.4 + Double(i) * 0.2,
                                           labels: [.calm, .grateful], associations: [.fitness, .family], metadata: nil))
            }
        }
        try await flush()

        // Heartbeat series, with a gap in some.
        for i in 0..<10 {
            let b = HKHeartbeatSeriesBuilder(healthStore: Health.store, device: watch, start: at(i * 3, 3))
            var t = 0.0
            for beat in 0..<60 {
                t += rng.range(0.7, 1.1)
                try await b.addHeartbeat(at: t, precededByGap: i % 3 == 0 && beat == 30)
            }
            try await b.addMetadata(tz)
            _ = try await b.finishSeries()
        }

        try await seedWorkouts(&rng)
    }

    private static func seedWorkouts(_ rng: inout RNG) async throws {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        // Six outdoor runs with route, pauses, laps, and per-second samples.
        for i in 0..<6 {
            let start = at(i * 5 + 1, 17.25), length = 1800.0 + Double(i) * 300
            let end = start.addingTimeInterval(length)
            let config = HKWorkoutConfiguration()
            config.activityType = .running
            config.locationType = .outdoor
            let b = HKWorkoutBuilder(healthStore: Health.store, configuration: config, device: watch)
            try await b.beginCollection(at: start)
            var samples: [HKSample] = []
            var t = 0.0
            while t < length {
                let s = start.addingTimeInterval(t)
                samples.append(HKQuantitySample(type: q(.heartRate), quantity: HKQuantity(unit: bpm, doubleValue: rng.range(130, 175).rounded()), start: s, end: s, device: watch, metadata: [HKMetadataKeyHeartRateMotionContext: NSNumber(value: 2)]))
                if Int(t) % 60 == 0 {
                    samples.append(HKQuantitySample(type: q(.activeEnergyBurned), quantity: HKQuantity(unit: .kilocalorie(), doubleValue: rng.range(9, 13)), start: s, end: s.addingTimeInterval(60), device: watch, metadata: nil))
                    samples.append(HKQuantitySample(type: q(.distanceWalkingRunning), quantity: HKQuantity(unit: .meter(), doubleValue: rng.range(160, 200)), start: s, end: s.addingTimeInterval(60), device: watch, metadata: nil))
                    samples.append(HKQuantitySample(type: q(.runningPower), quantity: HKQuantity(unit: .watt(), doubleValue: rng.range(190, 240)), start: s, end: s.addingTimeInterval(60), device: watch, metadata: nil))
                }
                t += 5
            }
            try await b.addSamples(samples)
            let pause = start.addingTimeInterval(600)
            try await b.addWorkoutEvents([
                HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: pause, duration: 0), metadata: nil),
                HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: pause.addingTimeInterval(45), duration: 0), metadata: nil),
                HKWorkoutEvent(type: .segment, dateInterval: DateInterval(start: start, duration: 1000), metadata: ["Segment": "1 km"]),
                HKWorkoutEvent(type: .lap, dateInterval: DateInterval(start: start.addingTimeInterval(900), duration: 0), metadata: nil),
            ])
            var meta: [String: Any] = tz
            meta[HKMetadataKeyIndoorWorkout] = false
            meta[HKMetadataKeyWeatherTemperature] = HKQuantity(unit: .degreeFahrenheit(), doubleValue: 51.8)
            meta[HKMetadataKeyWeatherHumidity] = HKQuantity(unit: .percent(), doubleValue: 0.76)
            meta[HKMetadataKeyAverageMETs] = HKQuantity(unit: HKUnit(from: "kcal/(kg*hr)"), doubleValue: 9.8)
            meta[HKMetadataKeyElevationAscended] = HKQuantity(unit: .meter(), doubleValue: 42)
            if i == 2 {
                meta[HKMetadataKeySyncIdentifier] = "other-app-\(i)"
                meta[HKMetadataKeySyncVersion] = NSNumber(value: 3)
            }
            try await b.addMetadata(meta)
            try await b.endCollection(at: end)
            guard let workout = try await b.finishWorkout() else { continue }

            let rb = HKWorkoutRouteBuilder(healthStore: Health.store, device: watch)
            var points: [CLLocation] = []
            for p in 0..<300 {
                let pt = start.addingTimeInterval(Double(p) * length / 300)
                points.append(CLLocation(coordinate: CLLocationCoordinate2D(latitude: 60.1699 + Double(p) * 0.0001, longitude: 24.9384 + sin(Double(p) / 20) * 0.002),
                                         altitude: 12 + Double(p % 17), horizontalAccuracy: 4, verticalAccuracy: 3, course: Double(p % 360), courseAccuracy: 5,
                                         speed: 3.1, speedAccuracy: 0.4, timestamp: pt))
            }
            try await rb.insertRouteData(points)
            _ = try await rb.finishRoute(with: workout, metadata: nil)
        }

        // Pool swim.
        do {
            let start = at(4, 7), end = start.addingTimeInterval(1500)
            let config = HKWorkoutConfiguration()
            config.activityType = .swimming
            config.swimmingLocationType = .pool
            config.lapLength = HKQuantity(unit: .meter(), doubleValue: 25)
            let b = HKWorkoutBuilder(healthStore: Health.store, configuration: config, device: watch)
            try await b.beginCollection(at: start)
            var samples: [HKSample] = []
            for lap in 0..<30 {
                let s = start.addingTimeInterval(Double(lap) * 50)
                samples.append(HKQuantitySample(type: q(.distanceSwimming), quantity: HKQuantity(unit: .meter(), doubleValue: 25), start: s, end: s.addingTimeInterval(45), device: watch, metadata: nil))
                samples.append(HKQuantitySample(type: q(.swimmingStrokeCount), quantity: HKQuantity(unit: .count(), doubleValue: 18), start: s, end: s.addingTimeInterval(45), device: watch,
                                                metadata: [HKMetadataKeySwimmingStrokeStyle: NSNumber(value: HKSwimmingStrokeStyle.freestyle.rawValue)]))
            }
            try await b.addSamples(samples)
            try await b.addMetadata([HKMetadataKeySwimmingLocationType: NSNumber(value: HKWorkoutSwimmingLocationType.pool.rawValue),
                                     HKMetadataKeyLapLength: HKQuantity(unit: .meter(), doubleValue: 25), HKMetadataKeyIndoorWorkout: true])
            try await b.endCollection(at: end)
            _ = try await b.finishWorkout()
        }

        // Swim, bike, run as one workout with three activities.
        if #available(iOS 16.0, *) {
            let start = at(20, 8), end = start.addingTimeInterval(3 * 1200)
            let config = HKWorkoutConfiguration()
            config.activityType = .swimBikeRun
            config.locationType = .outdoor
            let b = HKWorkoutBuilder(healthStore: Health.store, configuration: config, device: watch)
            try await b.beginCollection(at: start)
            let kinds: [HKWorkoutActivityType] = [.swimming, .cycling, .running]
            for (n, kind) in kinds.enumerated() {
                let cfg = HKWorkoutConfiguration()
                cfg.activityType = kind
                cfg.locationType = .outdoor
                if kind == .swimming { cfg.swimmingLocationType = .openWater }
                let s = start.addingTimeInterval(Double(n) * 1200)
                try await b.addWorkoutActivity(HKWorkoutActivity(workoutConfiguration: cfg, start: s, end: s.addingTimeInterval(1190), metadata: nil))
                var samples: [HKSample] = []
                for m in 0..<19 {
                    let ms = s.addingTimeInterval(Double(m) * 60)
                    samples.append(HKQuantitySample(type: q(.heartRate), quantity: HKQuantity(unit: bpm, doubleValue: 140 + Double(m)), start: ms, end: ms, device: watch, metadata: nil))
                    samples.append(HKQuantitySample(type: q(.activeEnergyBurned), quantity: HKQuantity(unit: .kilocalorie(), doubleValue: 11), start: ms, end: ms.addingTimeInterval(60), device: watch, metadata: nil))
                }
                try await b.addSamples(samples)
            }
            try await b.endCollection(at: end)
            _ = try await b.finishWorkout()
        }

        // A workout saved the old way: totals, no samples.
        let yoga = HCLegacyWorkout(.yoga, at(9, 19), at(9, 20), nil, HKQuantity(unit: .kilocalorie(), doubleValue: 180), nil, nil, nil, phone,
                                   [HKMetadataKeyIndoorWorkout: true, "App": "Some yoga app"])
        try await Health.store.save(yoga)
    }
}
#endif
