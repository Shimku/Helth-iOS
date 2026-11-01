#import "HCObjC.h"

NSString *HCCatch(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception.reason ?: exception.name;
    }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

HKWorkout *HCLegacyWorkout(HKWorkoutActivityType type, NSDate *start, NSDate *end,
                           NSArray<HKWorkoutEvent *> *events,
                           HKQuantity *energy, HKQuantity *distance,
                           HKQuantity *strokes, HKQuantity *flights,
                           HKDevice *device, NSDictionary<NSString *, id> *metadata) {
    if (flights != nil) {
        return [HKWorkout workoutWithActivityType:type startDate:start endDate:end workoutEvents:events
                                totalEnergyBurned:energy totalDistance:distance totalFlightsClimbed:flights
                                           device:device metadata:metadata];
    }
    if (strokes != nil) {
        return [HKWorkout workoutWithActivityType:type startDate:start endDate:end workoutEvents:events
                                totalEnergyBurned:energy totalDistance:distance totalSwimmingStrokeCount:strokes
                                           device:device metadata:metadata];
    }
    return [HKWorkout workoutWithActivityType:type startDate:start endDate:end workoutEvents:events
                            totalEnergyBurned:energy totalDistance:distance device:device metadata:metadata];
}

void HCAddSamplesToWorkout(HKHealthStore *store, NSArray<HKSample *> *samples, HKWorkout *workout,
                           void (^completion)(BOOL success, NSError *error)) {
    [store addSamples:samples toWorkout:workout completion:completion];
}

#pragma clang diagnostic pop
