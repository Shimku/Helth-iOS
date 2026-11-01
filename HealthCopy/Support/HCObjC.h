#import <Foundation/Foundation.h>
#import <HealthKit/HealthKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block and returns the reason of any Objective-C exception it raised, or nil.
/// HealthKit raises (instead of returning an error) when asked to share a type it reserves
/// for Apple, and HKUnit raises on a unit string it cannot parse. Swift cannot catch either.
NSString * _Nullable HCCatch(NS_NOESCAPE void (^block)(void));

/// A workout made the pre-iOS 17 way, with its totals given up front. Used for workouts that
/// carry totals but no samples (older apps saved them like this), and as a last resort when
/// HKWorkoutBuilder refuses one. Deprecated, so it lives here, away from Swift's warnings.
HKWorkout *HCLegacyWorkout(HKWorkoutActivityType type, NSDate *start, NSDate *end,
                           NSArray<HKWorkoutEvent *> * _Nullable events,
                           HKQuantity * _Nullable energy, HKQuantity * _Nullable distance,
                           HKQuantity * _Nullable strokes, HKQuantity * _Nullable flights,
                           HKDevice * _Nullable device, NSDictionary<NSString *, id> * _Nullable metadata);

/// Saves samples and ties them to an already saved workout (also deprecated since iOS 17).
void HCAddSamplesToWorkout(HKHealthStore *store, NSArray<HKSample *> *samples, HKWorkout *workout,
                           void (^completion)(BOOL success, NSError * _Nullable error));

NS_ASSUME_NONNULL_END
