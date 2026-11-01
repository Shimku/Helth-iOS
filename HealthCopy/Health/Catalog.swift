import HealthKit

/// Every quantity and category type in the iOS 27.1 SDK, by identifier suffix. Identifiers are
/// resolved at run time, so types newer than the phone's iOS simply come back nil.
enum Catalog {
    static let quantityPrefix = "HKQuantityTypeIdentifier"
    static let categoryPrefix = "HKCategoryTypeIdentifier"

    /// Suffix and the unit values are stored in (the SDK header's canonical unit).
    static let quantities: [(String, String)] = [
        ("AppleSleepingWristTemperature", "degC"), ("BodyFatPercentage", "%"), ("BodyMass", "kg"),
        ("BodyMassIndex", "count"), ("ElectrodermalActivity", "S"), ("Height", "m"), ("LeanBodyMass", "kg"),
        ("WaistCircumference", "m"), ("ActiveEnergyBurned", "kcal"), ("AppleExerciseTime", "min"),
        ("AppleMoveTime", "min"), ("AppleStandTime", "min"), ("BasalEnergyBurned", "kcal"),
        ("CrossCountrySkiingSpeed", "m/s"), ("CyclingCadence", "count/min"), ("CyclingFunctionalThresholdPower", "W"),
        ("CyclingPower", "W"), ("CyclingSpeed", "m/s"), ("DistanceCrossCountrySkiing", "m"), ("DistanceCycling", "m"),
        ("DistanceDownhillSnowSports", "m"), ("DistancePaddleSports", "m"), ("DistanceRowing", "m"),
        ("DistanceSkatingSports", "m"), ("DistanceSwimming", "m"), ("DistanceWalkingRunning", "m"),
        ("DistanceWheelchair", "m"), ("EstimatedWorkoutEffortScore", "appleEffortScore"), ("FlightsClimbed", "count"),
        ("NikeFuel", "count"), ("PaddleSportsSpeed", "m/s"), ("PhysicalEffort", "kcal/(kg*hr)"), ("PushCount", "count"),
        ("RowingSpeed", "m/s"), ("RunningPower", "W"), ("RunningSpeed", "m/s"), ("StepCount", "count"),
        ("SwimmingStrokeCount", "count"), ("UnderwaterDepth", "m"), ("WorkoutEffortScore", "appleEffortScore"),
        ("EnvironmentalAudioExposure", "dBASPL"), ("EnvironmentalSoundReduction", "dBASPL"),
        ("HeadphoneAudioExposure", "dBASPL"), ("AtrialFibrillationBurden", "%"), ("HeartRate", "count/min"),
        ("HeartRateRecoveryOneMinute", "count/min"), ("HeartRateVariabilityRMSSD", "ms"),
        ("HeartRateVariabilitySDNN", "ms"), ("PeripheralPerfusionIndex", "%"), ("RestingHeartRate", "count/min"),
        ("VO2Max", "ml/(kg*min)"), ("WalkingHeartRateAverage", "count/min"), ("AppleWalkingSteadiness", "%"),
        ("RunningGroundContactTime", "ms"), ("RunningStrideLength", "m"), ("RunningVerticalOscillation", "cm"),
        ("SixMinuteWalkTestDistance", "m"), ("StairAscentSpeed", "m/s"), ("StairDescentSpeed", "m/s"),
        ("WalkingAsymmetryPercentage", "%"), ("WalkingDoubleSupportPercentage", "%"), ("WalkingSpeed", "m/s"),
        ("WalkingStepLength", "m"), ("DietaryBiotin", "g"), ("DietaryCaffeine", "g"), ("DietaryCalcium", "g"),
        ("DietaryCarbohydrates", "g"), ("DietaryChloride", "g"), ("DietaryCholesterol", "g"), ("DietaryChromium", "g"),
        ("DietaryCopper", "g"), ("DietaryEnergyConsumed", "kcal"), ("DietaryFatMonounsaturated", "g"),
        ("DietaryFatPolyunsaturated", "g"), ("DietaryFatSaturated", "g"), ("DietaryFatTotal", "g"),
        ("DietaryFiber", "g"), ("DietaryFolate", "g"), ("DietaryIodine", "g"), ("DietaryIron", "g"),
        ("DietaryMagnesium", "g"), ("DietaryManganese", "g"), ("DietaryMolybdenum", "g"), ("DietaryNiacin", "g"),
        ("DietaryPantothenicAcid", "g"), ("DietaryPhosphorus", "g"), ("DietaryPotassium", "g"),
        ("DietaryProtein", "g"), ("DietaryRiboflavin", "g"), ("DietarySelenium", "g"), ("DietarySodium", "g"),
        ("DietarySugar", "g"), ("DietaryThiamin", "g"), ("DietaryVitaminA", "g"), ("DietaryVitaminB12", "g"),
        ("DietaryVitaminB6", "g"), ("DietaryVitaminC", "g"), ("DietaryVitaminD", "g"), ("DietaryVitaminE", "g"),
        ("DietaryVitaminK", "g"), ("DietaryWater", "mL"), ("DietaryZinc", "g"), ("BloodAlcoholContent", "%"),
        ("BloodPressureDiastolic", "mmHg"), ("BloodPressureSystolic", "mmHg"), ("InsulinDelivery", "IU"),
        ("NumberOfAlcoholicBeverages", "count"), ("NumberOfTimesFallen", "count"), ("TimeInDaylight", "min"),
        ("UVExposure", "count"), ("WaterTemperature", "degC"), ("BasalBodyTemperature", "degC"),
        ("AppleSleepingBreathingDisturbances", "count"), ("ForcedExpiratoryVolume1", "L"),
        ("ForcedVitalCapacity", "L"), ("InhalerUsage", "count"), ("OxygenSaturation", "%"),
        ("PeakExpiratoryFlowRate", "L/min"), ("RespiratoryRate", "count/min"), ("BloodGlucose", "mg/dL"),
        ("BodyTemperature", "degC"),
    ]

    static let categories: [String] = [
        "AppleStandHour", "EnvironmentalAudioExposureEvent", "HeadphoneAudioExposureEvent", "HighHeartRateEvent",
        "HypertensionEvent", "IrregularHeartRhythmEvent", "LowCardioFitnessEvent", "LowHeartRateEvent",
        "MindfulSession", "AppleWalkingSteadinessEvent", "HandwashingEvent", "ToothbrushingEvent",
        "BleedingAfterMenopause", "BleedingAfterPregnancy", "BleedingDuringPregnancy", "CervicalMucusQuality",
        "Contraceptive", "InfrequentMenstrualCycles", "IntermenstrualBleeding", "IrregularMenstrualCycles",
        "Lactation", "MenopausalState", "MenstrualFlow", "OvulationTestResult", "PersistentIntermenstrualBleeding",
        "Pregnancy", "PregnancyTestResult", "ProgesteroneTestResult", "ProlongedMenstrualPeriods",
        "SexualActivity", "SleepApneaEvent", "SleepAnalysis", "AbdominalCramps", "Acne", "AppetiteChanges",
        "BladderIncontinence", "Bloating", "BreastPain", "ChestTightnessOrPain", "Chills", "Constipation",
        "Coughing", "Diarrhea", "Dizziness", "DrySkin", "Fainting", "Fatigue", "Fever", "GeneralizedBodyAche",
        "HairLoss", "Headache", "Heartburn", "HotFlashes", "LossOfSmell", "LossOfTaste", "LowerBackPain",
        "MemoryLapse", "MoodChanges", "Nausea", "NightSweats", "PelvicPain", "RapidPoundingOrFlutteringHeartbeat",
        "RunnyNose", "ShortnessOfBreath", "SinusCongestion", "SkippedHeartbeat", "SleepChanges", "SoreThroat",
        "VaginalDryness", "Vomiting", "Wheezing",
    ]

    static let correlationTypes = ["HKCorrelationTypeIdentifierBloodPressure", "HKCorrelationTypeIdentifierFood"]

    static let workoutKey = "workout"
    static let routeKey = "route"
    static let heartbeatKey = "heartbeat"
    static let moodKey = "mood"

    static var quantityTypes: [(HKQuantityType, String)] {
        quantities.compactMap { suffix, unit in
            HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: quantityPrefix + suffix)).map { ($0, unit) }
        }
    }

    static var categoryTypes: [HKCategoryType] {
        categories.compactMap { HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: categoryPrefix + $0)) }
    }

    static func unitString(for identifier: String) -> String? {
        guard identifier.hasPrefix(quantityPrefix) else { return nil }
        let suffix = String(identifier.dropFirst(quantityPrefix.count))
        return quantities.first { $0.0 == suffix }?.1
    }

    /// The HealthKit sample type for a key in the manifest, if this iOS has it.
    static func sampleType(for key: String) -> HKSampleType? {
        switch key {
        case workoutKey: return HKObjectType.workoutType()
        case routeKey: return HKSeriesType.workoutRoute()
        case heartbeatKey: return HKSeriesType.heartbeat()
        case moodKey:
            if #available(iOS 18.0, *) { return HKObjectType.stateOfMindType() }
            return nil
        default:
            if key.hasPrefix(quantityPrefix) { return HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: key)) }
            if key.hasPrefix(categoryPrefix) { return HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: key)) }
            if key.hasPrefix("HKCorrelationTypeIdentifier") { return HKObjectType.correlationType(forIdentifier: HKCorrelationTypeIdentifier(rawValue: key)) }
            return nil
        }
    }

    // MARK: Names

    private static let names: [String: String] = [
        "StepCount": "Steps", "DistanceWalkingRunning": "Walking + Running Distance", "ActiveEnergyBurned": "Active Energy",
        "BasalEnergyBurned": "Resting Energy", "AppleExerciseTime": "Exercise Minutes", "AppleStandTime": "Stand Minutes",
        "AppleMoveTime": "Move Minutes", "AppleStandHour": "Stand Hours", "HeartRateVariabilitySDNN": "Heart Rate Variability",
        "HeartRateVariabilityRMSSD": "Heart Rate Variability (RMSSD)", "VO2Max": "Cardio Fitness",
        "OxygenSaturation": "Blood Oxygen", "SleepAnalysis": "Sleep", "MindfulSession": "Mindful Minutes",
        "MenstrualFlow": "Period", "DietaryWater": "Water", "DietaryEnergyConsumed": "Dietary Energy",
        "EnvironmentalAudioExposure": "Environmental Sound Levels", "HeadphoneAudioExposure": "Headphone Audio Levels",
        "AppleSleepingWristTemperature": "Wrist Temperature", "AppleSleepingBreathingDisturbances": "Breathing Disturbances",
        "BodyMass": "Weight", "BodyMassIndex": "Body Mass Index", "BodyFatPercentage": "Body Fat Percentage",
        "AppleWalkingSteadiness": "Walking Steadiness", "AppleWalkingSteadinessEvent": "Walking Steadiness Notifications",
        "HighHeartRateEvent": "High Heart Rate Notifications", "LowHeartRateEvent": "Low Heart Rate Notifications",
        "IrregularHeartRhythmEvent": "Irregular Rhythm Notifications", "LowCardioFitnessEvent": "Low Cardio Fitness Notifications",
        "EnvironmentalAudioExposureEvent": "Environmental Sound Notifications",
        "HeadphoneAudioExposureEvent": "Headphone Audio Notifications", "SleepApneaEvent": "Breathing Disturbance Notifications",
        "HypertensionEvent": "Hypertension Notifications", "WalkingHeartRateAverage": "Walking Heart Rate Average",
        "AtrialFibrillationBurden": "AFib History", "UVExposure": "UV Index", "FlightsClimbed": "Flights Climbed",
        "BloodPressureSystolic": "Blood Pressure (Systolic)", "BloodPressureDiastolic": "Blood Pressure (Diastolic)",
        "DietaryFatTotal": "Total Fat", "DietaryFatSaturated": "Saturated Fat", "DietaryFatMonounsaturated": "Monounsaturated Fat",
        "DietaryFatPolyunsaturated": "Polyunsaturated Fat", "NumberOfTimesFallen": "Falls",
        "ForcedExpiratoryVolume1": "Forced Expiratory Volume, 1 sec", "HKCorrelationTypeIdentifierBloodPressure": "Blood Pressure",
        "HKCorrelationTypeIdentifierFood": "Food", "RapidPoundingOrFlutteringHeartbeat": "Rapid, Pounding or Fluttering Heartbeat",
        "EstimatedWorkoutEffortScore": "Estimated Workout Effort", "WorkoutEffortScore": "Workout Effort",
        "RunningVerticalOscillation": "Vertical Oscillation", "RunningGroundContactTime": "Ground Contact Time",
        "RunningStrideLength": "Stride Length", "PhysicalEffort": "Physical Effort", "TimeInDaylight": "Time in Daylight",
        workoutKey: "Workouts", routeKey: "Workout Routes", heartbeatKey: "Heartbeat Series", moodKey: "State of Mind",
    ]

    static func name(for key: String) -> String {
        if let n = names[key] { return n }
        var suffix = key
        for prefix in [quantityPrefix, categoryPrefix, "HKCorrelationTypeIdentifier"] where key.hasPrefix(prefix) {
            suffix = String(key.dropFirst(prefix.count))
        }
        if let n = names[suffix] { return n }
        if suffix.hasPrefix("Dietary") { suffix = String(suffix.dropFirst("Dietary".count)) }
        // "VitaminB12" -> "Vitamin B12", "CervicalMucusQuality" -> "Cervical Mucus Quality"
        var out = ""
        let chars = Array(suffix)
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase, !(chars[i - 1].isUppercase && (i + 1 == chars.count || chars[i + 1].isUppercase)) { out += " " }
            out.append(c)
        }
        return out
    }
}
