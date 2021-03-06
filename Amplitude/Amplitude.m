//
// Amplitude.m

#ifndef AMPLITUDE_DEBUG
#define AMPLITUDE_DEBUG 0
#endif

#ifndef AMPLITUDE_LOG
#if AMPLITUDE_DEBUG
#   define AMPLITUDE_LOG(fmt, ...) NSLog(fmt, ##__VA_ARGS__)
#else
#   define AMPLITUDE_LOG(...)
#endif
#endif


#import "Amplitude.h"
#import "AMPLocationManagerDelegate.h"
#import "AMPARCMacros.h"
#import "AMPConstants.h"
#import "AMPDeviceInfo.h"
#import "AMPURLConnection.h"
#import "AMPDatabaseHelper.h"
#import "AMPUtils.h"
#import "AMPIdentify.h"
#import <math.h>
#import <sys/socket.h>
#import <sys/sysctl.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>
#include <sys/types.h>
#include <sys/sysctl.h>

@interface Amplitude ()

@property (nonatomic, strong) NSOperationQueue *backgroundQueue;
@property (nonatomic, strong) NSOperationQueue *initializerQueue;
@property (nonatomic, assign) BOOL initialized;
@property (nonatomic, assign) BOOL sslPinningEnabled;
@property (nonatomic, assign) long long sessionId;

@end

NSString *const kAMPSessionStartEvent = @"session_start";
NSString *const kAMPSessionEndEvent = @"session_end";
NSString *const kAMPRevenueEvent = @"revenue_amount";

static NSString *const BACKGROUND_QUEUE_NAME = @"BACKGROUND";
static NSString *const DATABASE_VERSION = @"database_version";
static NSString *const DEVICE_ID = @"device_id";
static NSString *const EVENTS = @"events";
static NSString *const EVENT_ID = @"event_id";
static NSString *const PREVIOUS_SESSION_ID = @"previous_session_id";
static NSString *const PREVIOUS_SESSION_TIME = @"previous_session_time";
static NSString *const MAX_EVENT_ID = @"max_event_id";
static NSString *const MAX_IDENTIFY_ID = @"max_identify_id";
static NSString *const OPT_OUT = @"opt_out";
static NSString *const USER_ID = @"user_id";
static NSString *const SEQUENCE_NUMBER = @"sequence_number";


@implementation Amplitude {
    NSString *_eventsDataPath;
    NSMutableDictionary *_propertyList;

    BOOL _updateScheduled;
    BOOL _updatingCurrently;
    UIBackgroundTaskIdentifier _uploadTaskID;

    AMPDeviceInfo *_deviceInfo;
    BOOL _useAdvertisingIdForDeviceId;

    CLLocation *_lastKnownLocation;
    BOOL _locationListeningEnabled;
    CLLocationManager *_locationManager;
    AMPLocationManagerDelegate *_locationManagerDelegate;

    BOOL _inForeground;
    BOOL _backoffUpload;
    int _backoffUploadBatchSize;
    BOOL _offline;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
#pragma mark - Static methods

+ (Amplitude *)instance {
    return [Amplitude instanceWithName:nil];
}

+ (Amplitude *)instanceWithName:(NSString*)instanceName {
    static NSMutableDictionary *_instances = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instances = [[NSMutableDictionary alloc] init];
    });

    // compiler wants explicit key nil check even though AMPUtils isEmptyString already has one
    if (instanceName == nil || [AMPUtils isEmptyString:instanceName]) {
        instanceName = kAMPDefaultInstance;
    }
    instanceName = [instanceName lowercaseString];

    Amplitude *client = nil;
    @synchronized(_instances) {
        client = [_instances objectForKey:instanceName];
        if (client == nil) {
            client = [[self alloc] initWithInstanceName:instanceName];
            [_instances setObject:client forKey:instanceName];
            SAFE_ARC_RELEASE(client);
        }
    }

    return client;
}

+ (void)initializeApiKey:(NSString*) apiKey {
    [[Amplitude instance] initializeApiKey:apiKey];
}

+ (void)initializeApiKey:(NSString*) apiKey userId:(NSString*) userId {
    [[Amplitude instance] initializeApiKey:apiKey userId:userId];
}

+ (void)logEvent:(NSString*) eventType {
    [[Amplitude instance] logEvent:eventType];
}

+ (void)logEvent:(NSString*) eventType withEventProperties:(NSDictionary*) eventProperties {
    [[Amplitude instance] logEvent:eventType withEventProperties:eventProperties];
}

+ (void)logRevenue:(NSNumber*) amount {
    [[Amplitude instance] logRevenue:amount];
}

+ (void)logRevenue:(NSString*) productIdentifier quantity:(NSInteger) quantity price:(NSNumber*) price {
    [[Amplitude instance] logRevenue:productIdentifier quantity:quantity price:price];
}

+ (void)logRevenue:(NSString*) productIdentifier quantity:(NSInteger) quantity price:(NSNumber*) price receipt:(NSData*) receipt {
    [[Amplitude instance] logRevenue:productIdentifier quantity:quantity price:price receipt:receipt];
}

+ (void)uploadEvents {
    [[Amplitude instance] uploadEvents];
}

+ (void)setUserProperties:(NSDictionary*) userProperties {
    [[Amplitude instance] setUserProperties:userProperties];
}

+ (void)setUserId:(NSString*) userId {
    [[Amplitude instance] setUserId:userId];
}

+ (void)enableLocationListening {
    [[Amplitude instance] enableLocationListening];
}

+ (void)disableLocationListening {
    [[Amplitude instance] disableLocationListening];
}

+ (void)useAdvertisingIdForDeviceId {
    [[Amplitude instance] useAdvertisingIdForDeviceId];
}

+ (void)printEventsCount {
    [[Amplitude instance] printEventsCount];
}

+ (NSString*)getDeviceId {
    return [[Amplitude instance] getDeviceId];
}

+ (void)updateLocation
{
    [[Amplitude instance] updateLocation];
}

#pragma mark - Main class methods
- (id)init
{
    return [self initWithInstanceName:nil];
}

- (id)initWithInstanceName:(NSString*) instanceName
{
    if ([AMPUtils isEmptyString:instanceName]) {
        instanceName = kAMPDefaultInstance;
    }
    instanceName = [instanceName lowercaseString];

    if (self = [super init]) {

#if AMPLITUDE_SSL_PINNING
        _sslPinningEnabled = YES;
#else
        _sslPinningEnabled = NO;
#endif

        _initialized = NO;
        _locationListeningEnabled = YES;
        _sessionId = -1;
        _updateScheduled = NO;
        _updatingCurrently = NO;
        _useAdvertisingIdForDeviceId = NO;
        _backoffUpload = NO;
        _offline = NO;
        _instanceName = SAFE_ARC_RETAIN(instanceName);

        self.eventUploadThreshold = kAMPEventUploadThreshold;
        self.eventMaxCount = kAMPEventMaxCount;
        self.eventUploadMaxBatchSize = kAMPEventUploadMaxBatchSize;
        self.eventUploadPeriodSeconds = kAMPEventUploadPeriodSeconds;
        self.minTimeBetweenSessionsMillis = kAMPMinTimeBetweenSessionsMillis;
        _backoffUploadBatchSize = self.eventUploadMaxBatchSize;

        _initializerQueue = [[NSOperationQueue alloc] init];
        _backgroundQueue = [[NSOperationQueue alloc] init];
        // Force method calls to happen in FIFO order by only allowing 1 concurrent operation
        [_backgroundQueue setMaxConcurrentOperationCount:1];
        // Ensure initialize finishes running asynchronously before other calls are run
        [_backgroundQueue setSuspended:YES];
        // Name the queue so runOnBackgroundQueue can tell which queue an operation is running
        _backgroundQueue.name = BACKGROUND_QUEUE_NAME;

        [_initializerQueue addOperationWithBlock:^{

            _deviceInfo = [[AMPDeviceInfo alloc] init];

            _uploadTaskID = UIBackgroundTaskInvalid;
            
            NSString *eventsDataDirectory = [AMPUtils platformDataDirectory];
            NSString *propertyListPath = [eventsDataDirectory stringByAppendingPathComponent:@"com.amplitude.plist"];
            if (![_instanceName isEqualToString:kAMPDefaultInstance]) {
                propertyListPath = [NSString stringWithFormat:@"%@_%@", propertyListPath, _instanceName]; // namespace pList with instance name
            }
            _propertyListPath = SAFE_ARC_RETAIN(propertyListPath);

            [self upgradePrefs];

            // Load propertyList object
            _propertyList = SAFE_ARC_RETAIN([self deserializePList:_propertyListPath]);
            if (!_propertyList) {
                _propertyList = SAFE_ARC_RETAIN([NSMutableDictionary dictionary]);
                [_propertyList setObject:[NSNumber numberWithInt:1] forKey:DATABASE_VERSION];
                BOOL success = [self savePropertyList];
                if (!success) {
                    NSLog(@"ERROR: Unable to save propertyList to file on initialization");
                }
            } else {
                AMPLITUDE_LOG(@"Loaded from %@", _propertyListPath);
            }

            // update database if necessary
            int oldDBVersion = 1;
            NSNumber *oldDBVersionSaved = [_propertyList objectForKey:DATABASE_VERSION];
            if (oldDBVersionSaved != nil) {
                oldDBVersion = [oldDBVersionSaved intValue];
            }

            // update the database
            if (oldDBVersion < kAMPDBVersion) {
                if ([[AMPDatabaseHelper getDatabaseHelper: _instanceName] upgrade:oldDBVersion newVersion:kAMPDBVersion]) {
                    [_propertyList setObject:[NSNumber numberWithInt:kAMPDBVersion] forKey:DATABASE_VERSION];
                    [self savePropertyList];
                }
            }

            // only on default instance, migrate all of old _eventsData object to database store if database just created
            if ([_instanceName isEqualToString:kAMPDefaultInstance] && oldDBVersion < kAMPDBFirstVersion) {
                _eventsDataPath = SAFE_ARC_RETAIN([eventsDataDirectory stringByAppendingPathComponent:@"com.amplitude.archiveDict"]);
                if ([self migrateEventsDataToDB]) {
                    // delete events data so don't need to migrate next time
                    if ([[NSFileManager defaultManager] fileExistsAtPath:_eventsDataPath]) {
                        [[NSFileManager defaultManager] removeItemAtPath:_eventsDataPath error:NULL];
                    }
                }
                SAFE_ARC_RELEASE(_eventsDataPath);
            }

            // try to restore previous session
            long long previousSessionId = [self previousSessionId];
            if (previousSessionId >= 0) {
                _sessionId = previousSessionId;
            }

            [self initializeDeviceId];

            [_backgroundQueue setSuspended:NO];
        }];

        // CLLocationManager must be created on the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            Class CLLocationManager = NSClassFromString(@"CLLocationManager");
            _locationManager = [[CLLocationManager alloc] init];
            _locationManagerDelegate = [[AMPLocationManagerDelegate alloc] init];
            SEL setDelegate = NSSelectorFromString(@"setDelegate:");
            [_locationManager performSelector:setDelegate withObject:_locationManagerDelegate];
        });

        [self addObservers];
    }
    return self;
};

// maintain backwards compatibility on default instance
- (BOOL) migrateEventsDataToDB
{
    NSDictionary *eventsData = [self unarchive:_eventsDataPath];
    if (eventsData == nil) {
        return NO;
    }

    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper];
    BOOL success = YES;

    // migrate events
    NSArray *events = [eventsData objectForKey:EVENTS];
    for (id event in events) {
        NSError *error = nil;
        NSData *jsonData = nil;
        @try {
            jsonData = [NSJSONSerialization dataWithJSONObject:[AMPUtils makeJSONSerializable:event] options:0 error:&error];
        }
        @catch (NSException *exception) {
            NSLog(@"ERROR: NSJSONSerialization error: %@", exception.reason);
            continue;
        }
        if (error != nil) {
            NSLog(@"ERROR: NSJSONSerialization error: %@", error);
            continue;
        }
        NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        success &= [dbHelper addEvent:jsonString];
        SAFE_ARC_RELEASE(jsonString);
    }

    // migrate remaining properties
    NSString *userId = [eventsData objectForKey:USER_ID];
    if (userId != nil) {
        success &= [dbHelper insertOrReplaceKeyValue:USER_ID value:userId];
    }
    NSNumber *optOut = [eventsData objectForKey:OPT_OUT];
    if (optOut != nil) {
        success &= [dbHelper insertOrReplaceKeyLongValue:OPT_OUT value:optOut];
    }
    NSString *deviceId = [eventsData objectForKey:DEVICE_ID];
    if (deviceId != nil) {
        success &= [dbHelper insertOrReplaceKeyValue:DEVICE_ID value:deviceId];
    }
    NSNumber *previousSessionId = [eventsData objectForKey:PREVIOUS_SESSION_ID];
    if (previousSessionId != nil) {
        success &= [dbHelper insertOrReplaceKeyLongValue:PREVIOUS_SESSION_ID value:previousSessionId];
    }
    NSNumber *previousSessionTime = [eventsData objectForKey:PREVIOUS_SESSION_TIME];
    if (previousSessionTime != nil) {
        success &= [dbHelper insertOrReplaceKeyLongValue:PREVIOUS_SESSION_TIME value:previousSessionTime];
    }

    return success;
}

- (void) addObservers
{
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(enterForeground)
                   name:UIApplicationWillEnterForegroundNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(enterBackground)
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];
}

- (void) removeObservers
{
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:self name:UIApplicationWillEnterForegroundNotification object:nil];
    [center removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
}

- (void) dealloc {
    [self removeObservers];

    // Release properties
    SAFE_ARC_RELEASE(_apiKey);
    SAFE_ARC_RELEASE(_backgroundQueue);
    SAFE_ARC_RELEASE(_deviceId);
    SAFE_ARC_RELEASE(_userId);

    // Release instance variables
    SAFE_ARC_RELEASE(_deviceInfo);
    SAFE_ARC_RELEASE(_initializerQueue);
    SAFE_ARC_RELEASE(_lastKnownLocation);
    SAFE_ARC_RELEASE(_locationManager);
    SAFE_ARC_RELEASE(_locationManagerDelegate);
    SAFE_ARC_RELEASE(_propertyList);
    SAFE_ARC_RELEASE(_propertyListPath);
    SAFE_ARC_RELEASE(_instanceName);

    SAFE_ARC_SUPER_DEALLOC();
}

- (void)initializeApiKey:(NSString*) apiKey
{
    [self initializeApiKey:apiKey userId:nil setUserId: NO];
}

/**
 * Initialize Amplitude with a given apiKey and userId.
 */
- (void)initializeApiKey:(NSString*) apiKey userId:(NSString*) userId
{
    [self initializeApiKey:apiKey userId:userId setUserId: YES];
}

/**
 * SetUserId: client explicitly initialized with a userId (can be nil).
 * If setUserId is NO, then attempt to load userId from saved eventsData.
 */
- (void)initializeApiKey:(NSString*) apiKey userId:(NSString*) userId setUserId:(BOOL) setUserId
{
    if (apiKey == nil) {
        NSLog(@"ERROR: apiKey cannot be nil in initializeApiKey:");
        return;
    }

    if (![self isArgument:apiKey validType:[NSString class] methodName:@"initializeApiKey:"]) {
        return;
    }
    if (userId != nil && ![self isArgument:userId validType:[NSString class] methodName:@"initializeApiKey:"]) {
        return;
    }

    if ([apiKey length] == 0) {
        NSLog(@"ERROR: apiKey cannot be blank in initializeApiKey:");
        return;
    }
    SAFE_ARC_RETAIN(apiKey);
    SAFE_ARC_RELEASE(_apiKey);
    _apiKey = apiKey;

    [self runOnBackgroundQueue:^{
        if (setUserId) {
            [self setUserId:userId];
        } else {
            _userId = SAFE_ARC_RETAIN([[AMPDatabaseHelper getDatabaseHelper:_instanceName] getValue:USER_ID]);
        }
    }];

    UIApplicationState state = [UIApplication sharedApplication].applicationState;
    if (state != UIApplicationStateBackground) {
        // If this is called while the app is running in the background, for example
        // via a push notification, don't call enterForeground
        [self enterForeground];
    }
    _initialized = YES;
}

- (void)initializeApiKey:(NSString*) apiKey userId:(NSString*) userId startSession:(BOOL)startSession
{
    [self initializeApiKey:apiKey userId:userId];
}

/**
 * Run a block in the background. If already in the background, run immediately.
 */
- (BOOL)runOnBackgroundQueue:(void (^)(void))block
{
    if ([[NSOperationQueue currentQueue].name isEqualToString:BACKGROUND_QUEUE_NAME]) {
        AMPLITUDE_LOG(@"Already running in the background.");
        block();
        return NO;
    }
    else {
        [_backgroundQueue addOperationWithBlock:block];
        return YES;
    }
}

#pragma mark - logEvent

- (void)logEvent:(NSString*) eventType
{
    [self logEvent:eventType withEventProperties:nil];
}

- (void)logEvent:(NSString*) eventType withEventProperties:(NSDictionary*) eventProperties
{
    [self logEvent:eventType withEventProperties:eventProperties outOfSession:NO];
}

- (void)logEvent:(NSString*) eventType withEventProperties:(NSDictionary*) eventProperties outOfSession:(BOOL) outOfSession
{
    [self logEvent:eventType withEventProperties:eventProperties withApiProperties:nil withUserProperties:nil withTimestamp:nil outOfSession:outOfSession];
}

- (void)logEvent:(NSString*) eventType withEventProperties:(NSDictionary*) eventProperties withApiProperties:(NSDictionary*) apiProperties withUserProperties:(NSDictionary*) userProperties withTimestamp:(NSNumber*) timestamp outOfSession:(BOOL) outOfSession
{
    if (_apiKey == nil) {
        NSLog(@"ERROR: apiKey cannot be nil or empty, set apiKey with initializeApiKey: before calling logEvent");
        return;
    }

    if (![self isArgument:eventType validType:[NSString class] methodName:@"logEvent"]) {
        return;
    }
    if (eventProperties != nil && ![self isArgument:eventProperties validType:[NSDictionary class] methodName:@"logEvent"]) {
        return;
    }

    if (timestamp == nil) {
        timestamp = [NSNumber numberWithLongLong:[[self currentTime] timeIntervalSince1970] * 1000];
    }

    // Create snapshot of all event json objects, to prevent deallocation crash
    eventProperties = [eventProperties copy];
    apiProperties = [apiProperties mutableCopy];
    userProperties = [userProperties copy];

    [self runOnBackgroundQueue:^{
        AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper:_instanceName];

        // Respect the opt-out setting by not sending or storing any events.
        if ([self optOut])  {
            NSLog(@"User has opted out of tracking. Event %@ not logged.", eventType);
            SAFE_ARC_RELEASE(eventProperties);
            SAFE_ARC_RELEASE(apiProperties);
            SAFE_ARC_RELEASE(userProperties);
            return;
        }

        // skip session check if logging start_session or end_session events
        BOOL loggingSessionEvent = _trackingSessionEvents && ([eventType isEqualToString:kAMPSessionStartEvent] || [eventType isEqualToString:kAMPSessionEndEvent]);
        if (!loggingSessionEvent && !outOfSession) {
            [self startOrContinueSession:timestamp];
        }

        NSMutableDictionary *event = [NSMutableDictionary dictionary];
        [event setValue:eventType forKey:@"event_type"];
        [event setValue:[self truncate:[AMPUtils makeJSONSerializable:[self replaceWithEmptyJSON:eventProperties]]] forKey:@"event_properties"];
        [event setValue:[self replaceWithEmptyJSON:apiProperties] forKey:@"api_properties"];
        [event setValue:[self truncate:[AMPUtils makeJSONSerializable:[self replaceWithEmptyJSON:userProperties]]] forKey:@"user_properties"];
        [event setValue:[NSNumber numberWithLongLong:outOfSession ? -1 : _sessionId] forKey:@"session_id"];
        [event setValue:timestamp forKey:@"timestamp"];

        SAFE_ARC_RELEASE(eventProperties);
        SAFE_ARC_RELEASE(apiProperties);
        SAFE_ARC_RELEASE(userProperties);

        [self annotateEvent:event];

        // convert event dictionary to JSON String
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:[AMPUtils makeJSONSerializable:event] options:0 error:NULL];
        NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        if ([eventType isEqualToString:IDENTIFY_EVENT]) {
            [dbHelper addIdentify:jsonString];
        } else {
            [dbHelper addEvent:jsonString];
        }
        SAFE_ARC_RELEASE(jsonString);

        AMPLITUDE_LOG(@"Logged %@ Event", event[@"event_type"]);

        [self truncateEventQueues];

        int eventCount = [dbHelper getTotalEventCount]; // refetch since events may have been deleted
        if ((eventCount % self.eventUploadThreshold) == 0 && eventCount >= self.eventUploadThreshold) {
            [self uploadEvents];
        } else {
            [self uploadEventsWithDelay:self.eventUploadPeriodSeconds];
        }
    }];
}

- (void)truncateEventQueues
{
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper:_instanceName];
    int numEventsToRemove = MIN(MAX(1, self.eventMaxCount/10), kAMPEventRemoveBatchSize);
    int eventCount = [dbHelper getEventCount];
    if (eventCount > self.eventMaxCount) {
        [dbHelper removeEvents:([dbHelper getNthEventId:numEventsToRemove])];
    }
    int identifyCount = [dbHelper getIdentifyCount];
    if (identifyCount > self.eventMaxCount) {
        [dbHelper removeIdentifys:([dbHelper getNthIdentifyId:numEventsToRemove])];
    }
}

- (void)annotateEvent:(NSMutableDictionary*) event
{
    [event setValue:_userId forKey:@"user_id"];
    [event setValue:_deviceId forKey:@"device_id"];
    [event setValue:kAMPPlatform forKey:@"platform"];
    [event setValue:_deviceInfo.appVersion forKey:@"version_name"];
    [event setValue:_deviceInfo.osName forKey:@"os_name"];
    [event setValue:_deviceInfo.osVersion forKey:@"os_version"];
    [event setValue:_deviceInfo.model forKey:@"device_model"];
    [event setValue:_deviceInfo.manufacturer forKey:@"device_manufacturer"];
    [event setValue:_deviceInfo.carrier forKey:@"carrier"];
    [event setValue:_deviceInfo.country forKey:@"country"];
    [event setValue:_deviceInfo.language forKey:@"language"];
    NSDictionary *library = @{
        @"name": kAMPLibrary,
        @"version": kAMPVersion
    };
    [event setValue:library forKey:@"library"];
    [event setValue:[AMPUtils generateUUID] forKey:@"uuid"];
    [event setValue:[NSNumber numberWithLongLong:[self getNextSequenceNumber]] forKey:@"sequence_number"];

    NSMutableDictionary *apiProperties = [event valueForKey:@"api_properties"];

    NSString* advertiserID = _deviceInfo.advertiserID;
    if (advertiserID) {
        [apiProperties setValue:advertiserID forKey:@"ios_idfa"];
    }
    NSString* vendorID = _deviceInfo.vendorID;
    if (vendorID) {
        [apiProperties setValue:vendorID forKey:@"ios_idfv"];
    }

    if (_lastKnownLocation != nil) {
        @synchronized (_locationManager) {
            NSMutableDictionary *location = [NSMutableDictionary dictionary];

            // Need to use NSInvocation because coordinate selector returns a C struct
            SEL coordinateSelector = NSSelectorFromString(@"coordinate");
            NSMethodSignature *coordinateMethodSignature = [_lastKnownLocation methodSignatureForSelector:coordinateSelector];
            NSInvocation *coordinateInvocation = [NSInvocation invocationWithMethodSignature:coordinateMethodSignature];
            [coordinateInvocation setTarget:_lastKnownLocation];
            [coordinateInvocation setSelector:coordinateSelector];
            [coordinateInvocation invoke];
            CLLocationCoordinate2D lastKnownLocationCoordinate;
            [coordinateInvocation getReturnValue:&lastKnownLocationCoordinate];

            [location setValue:[NSNumber numberWithDouble:lastKnownLocationCoordinate.latitude] forKey:@"lat"];
            [location setValue:[NSNumber numberWithDouble:lastKnownLocationCoordinate.longitude] forKey:@"lng"];

            [apiProperties setValue:location forKey:@"location"];
        }
    }
}

#pragma mark - logRevenue

// amount is a double in units of dollars
// ex. $3.99 would be passed as [NSNumber numberWithDouble:3.99]
- (void)logRevenue:(NSNumber*) amount
{
    [self logRevenue:nil quantity:1 price:amount];
}

- (void)logRevenue:(NSString*) productIdentifier quantity:(NSInteger) quantity price:(NSNumber*) price
{
    [self logRevenue:productIdentifier quantity:quantity price:price receipt:nil];
}

- (void)logRevenue:(NSString*) productIdentifier quantity:(NSInteger) quantity price:(NSNumber*) price receipt:(NSData*) receipt
{
    if (_apiKey == nil) {
        NSLog(@"ERROR: apiKey cannot be nil or empty, set apiKey with initializeApiKey: before calling logRevenue:");
        return;
    }
    if (![self isArgument:price validType:[NSNumber class] methodName:@"logRevenue:"]) {
        return;
    }
    NSDictionary *apiProperties = [NSMutableDictionary dictionary];
    [apiProperties setValue:kAMPRevenueEvent forKey:@"special"];
    [apiProperties setValue:productIdentifier forKey:@"productId"];
    [apiProperties setValue:[NSNumber numberWithInteger:quantity] forKey:@"quantity"];
    [apiProperties setValue:price forKey:@"price"];

    if ([receipt respondsToSelector:@selector(base64EncodedStringWithOptions:)]) {
        [apiProperties setValue:[receipt base64EncodedStringWithOptions:0] forKey:@"receipt"];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated"
        [apiProperties setValue:[receipt base64Encoding] forKey:@"receipt"];
#pragma clang diagnostic pop
    }

    [self logEvent:kAMPRevenueEvent withEventProperties:nil withApiProperties:apiProperties withUserProperties:nil withTimestamp:nil outOfSession:NO];
}

#pragma mark - Upload events

- (void)uploadEventsWithDelay:(int) delay
{
    if (!_updateScheduled) {
        _updateScheduled = YES;
        __block __weak Amplitude *weakSelf = self;
        [_backgroundQueue addOperationWithBlock:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf performSelector:@selector(uploadEventsInBackground) withObject:nil afterDelay:delay];
            });
        }];
    }
}

- (void)uploadEventsInBackground
{
    _updateScheduled = NO;
    [self uploadEvents];
}

- (void)uploadEvents
{
    int limit = _backoffUpload ? _backoffUploadBatchSize : self.eventUploadMaxBatchSize;
    [self uploadEventsWithLimit:limit];
}

- (void)uploadEventsWithLimit:(int) limit
{
    if (_apiKey == nil) {
        NSLog(@"ERROR: apiKey cannot be nil or empty, set apiKey with initializeApiKey: before calling uploadEvents:");
        return;
    }

    @synchronized (self) {
        if (_updatingCurrently) {
            return;
        }
        _updatingCurrently = YES;
    }

    [self runOnBackgroundQueue:^{

        // Don't communicate with the server if the user has opted out.
        if ([self optOut] || _offline)  {
            _updatingCurrently = NO;
            return;
        }

        AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper:_instanceName];
        long eventCount = [dbHelper getTotalEventCount];
        long numEvents = limit > 0 ? fminl(eventCount, limit) : eventCount;
        if (numEvents == 0) {
            _updatingCurrently = NO;
            return;
        }
        NSMutableArray *events = [dbHelper getEvents:-1 limit:numEvents];
        NSMutableArray *identifys = [dbHelper getIdentifys:-1 limit:numEvents];
        NSDictionary *merged = [self mergeEventsAndIdentifys:events identifys:identifys numEvents:numEvents];

        NSMutableArray *uploadEvents = [merged objectForKey:EVENTS];
        long long maxEventId = [[merged objectForKey:MAX_EVENT_ID] longLongValue];
        long long maxIdentifyId = [[merged objectForKey:MAX_IDENTIFY_ID] longLongValue];

        NSError *error = nil;
        NSData *eventsDataLocal = nil;
        @try {
            eventsDataLocal = [NSJSONSerialization dataWithJSONObject:uploadEvents options:0 error:&error];
        }
        @catch (NSException *exception) {
            NSLog(@"ERROR: NSJSONSerialization error: %@", exception.reason);
            _updatingCurrently = NO;
            return;
        }
        if (error != nil) {
            NSLog(@"ERROR: NSJSONSerialization error: %@", error);
            _updatingCurrently = NO;
            return;
        }
        if (eventsDataLocal) {
            NSString *eventsString = [[NSString alloc] initWithData:eventsDataLocal encoding:NSUTF8StringEncoding];
            [self makeEventUploadPostRequest:kAMPEventLogUrl events:eventsString maxEventId:maxEventId maxIdentifyId:maxIdentifyId];
            SAFE_ARC_RELEASE(eventsString);
       }
    }];
}

- (long long)getNextSequenceNumber
{
    AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper:_instanceName];
    NSNumber *sequenceNumberFromDB = [dbHelper getLongValue:SEQUENCE_NUMBER];
    long long sequenceNumber = 0;
    if (sequenceNumberFromDB != nil) {
        sequenceNumber = [sequenceNumberFromDB longLongValue];
    }

    sequenceNumber++;
    [dbHelper insertOrReplaceKeyLongValue:SEQUENCE_NUMBER value:[NSNumber numberWithLongLong:sequenceNumber]];

    return sequenceNumber;
}

- (NSDictionary*)mergeEventsAndIdentifys:(NSMutableArray*)events identifys:(NSMutableArray*)identifys numEvents:(long) numEvents
{
    NSMutableArray *mergedEvents = [[NSMutableArray alloc] init];
    long long maxEventId = -1;
    long long maxIdentifyId = -1;

    // NSArrays actually have O(1) performance for push/pop
    while ([mergedEvents count] < numEvents) {
        NSDictionary *event = nil;
        NSDictionary *identify = nil;

        // case 1: no identifys grab from events
        if ([identifys count] == 0) {
            event = SAFE_ARC_RETAIN(events[0]);
            [events removeObjectAtIndex:0];
            maxEventId = [[event objectForKey:@"event_id"] longValue];

        // case 2: no events grab from identifys
        } else if ([events count] == 0) {
            identify = SAFE_ARC_RETAIN(identifys[0]);
            [identifys removeObjectAtIndex:0];
            maxIdentifyId = [[identify objectForKey:@"event_id"] longValue];

        // case 3: need to compare sequence numbers
        } else {
            // events logged before v3.2.0 won't have sequeunce number, put those first
            event = SAFE_ARC_RETAIN(events[0]);
            identify = SAFE_ARC_RETAIN(identifys[0]);
            if ([event objectForKey:SEQUENCE_NUMBER] == nil ||
                    ([[event objectForKey:SEQUENCE_NUMBER] longLongValue] <
                     [[identify objectForKey:SEQUENCE_NUMBER] longLongValue])) {
                [events removeObjectAtIndex:0];
                maxEventId = [[event objectForKey:EVENT_ID] longValue];
                SAFE_ARC_RELEASE(identify);
                identify = nil;
            } else {
                [identifys removeObjectAtIndex:0];
                maxIdentifyId = [[identify objectForKey:EVENT_ID] longValue];
                SAFE_ARC_RELEASE(event);
                event = nil;
            }
        }

        [mergedEvents addObject: event != nil ? event : identify];
        SAFE_ARC_RELEASE(event);
        SAFE_ARC_RELEASE(identify);
    }

    NSDictionary *results = [[NSDictionary alloc] initWithObjectsAndKeys: mergedEvents, EVENTS, [NSNumber numberWithLongLong:maxEventId], MAX_EVENT_ID, [NSNumber numberWithLongLong:maxIdentifyId], MAX_IDENTIFY_ID, nil];
    SAFE_ARC_RELEASE(mergedEvents);
    return SAFE_ARC_AUTORELEASE(results);
}

- (void)makeEventUploadPostRequest:(NSString*) url events:(NSString*) events maxEventId:(long long) maxEventId maxIdentifyId:(long long) maxIdentifyId
{
    NSMutableURLRequest *request =[NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [request setTimeoutInterval:60.0];

    NSString *apiVersionString = [[NSNumber numberWithInt:kAMPApiVersion] stringValue];

    NSMutableData *postData = [[NSMutableData alloc] init];
    [postData appendData:[@"v=" dataUsingEncoding:NSUTF8StringEncoding]];
    [postData appendData:[apiVersionString dataUsingEncoding:NSUTF8StringEncoding]];
    [postData appendData:[@"&client=" dataUsingEncoding:NSUTF8StringEncoding]];
    [postData appendData:[_apiKey dataUsingEncoding:NSUTF8StringEncoding]];
    [postData appendData:[@"&e=" dataUsingEncoding:NSUTF8StringEncoding]];
    [postData appendData:[[self urlEncodeString:events] dataUsingEncoding:NSUTF8StringEncoding]];

    // Add timestamp of upload
    [postData appendData:[@"&upload_time=" dataUsingEncoding:NSUTF8StringEncoding]];
    NSString *timestampString = [[NSNumber numberWithLongLong:[[self currentTime] timeIntervalSince1970] * 1000] stringValue];
    [postData appendData:[timestampString dataUsingEncoding:NSUTF8StringEncoding]];

    // Add checksum
    [postData appendData:[@"&checksum=" dataUsingEncoding:NSUTF8StringEncoding]];
    NSString *checksumData = [NSString stringWithFormat: @"%@%@%@%@", apiVersionString, _apiKey, events, timestampString];
    NSString *checksum = [self md5HexDigest: checksumData];
    [postData appendData:[checksum dataUsingEncoding:NSUTF8StringEncoding]];

    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"%lu", (unsigned long)[postData length]] forHTTPHeaderField:@"Content-Length"];

    [request setHTTPBody:postData];
    AMPLITUDE_LOG(@"Events: %@", events);

    SAFE_ARC_RELEASE(postData);

    // If pinning is enabled, use the AMPURLConnection that handles it.
#if AMPLITUDE_SSL_PINNING
    id Connection = (self.sslPinningEnabled ? [AMPURLConnection class] : [NSURLConnection class]);
#else
    id Connection = [NSURLConnection class];
#endif
    [Connection sendAsynchronousRequest:request queue:_backgroundQueue completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
        AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper:_instanceName];
        BOOL uploadSuccessful = NO;
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*)response;
        if (response != nil) {
            if ([httpResponse statusCode] == 200) {
                NSString *result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if ([result isEqualToString:@"success"]) {
                    // success, remove existing events from dictionary
                    uploadSuccessful = YES;
                    if (maxEventId >= 0) {
                        [dbHelper removeEvents:maxEventId];
                    }
                    if (maxIdentifyId >= 0) {
                        [dbHelper removeIdentifys:maxIdentifyId];
                    }
                } else if ([result isEqualToString:@"invalid_api_key"]) {
                    NSLog(@"ERROR: Invalid API Key, make sure your API key is correct in initializeApiKey:");
                } else if ([result isEqualToString:@"bad_checksum"]) {
                    NSLog(@"ERROR: Bad checksum, post request was mangled in transit, will attempt to reupload later");
                } else if ([result isEqualToString:@"request_db_write_failed"]) {
                    NSLog(@"ERROR: Couldn't write to request database on server, will attempt to reupload later");
                } else {
                    NSLog(@"ERROR: %@, will attempt to reupload later", result);
                }
                SAFE_ARC_RELEASE(result);
            } else if ([httpResponse statusCode] == 413) {
                // If blocked by one massive event, drop it
                if (_backoffUpload && _backoffUploadBatchSize == 1) {
                    if (maxEventId >= 0) {
                        [dbHelper removeEvent: maxEventId];
                    }
                    if (maxIdentifyId >= 0) {
                        [dbHelper removeIdentifys: maxIdentifyId];
                    }
                }

                // server complained about length of request, backoff and try again
                _backoffUpload = YES;
                int numEvents = fminl([dbHelper getEventCount], _backoffUploadBatchSize);
                _backoffUploadBatchSize = (int)ceilf(numEvents / 2.0f);
                AMPLITUDE_LOG(@"Request too large, will decrease size and attempt to reupload");
                _updatingCurrently = NO;
                [self uploadEventsWithLimit:_backoffUploadBatchSize];

            } else {
                NSLog(@"ERROR: Connection response received:%ld, %@", (long)[httpResponse statusCode],
                    SAFE_ARC_AUTORELEASE([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]));
            }
        } else if (error != nil) {
            if ([error code] == -1009) {
                AMPLITUDE_LOG(@"No internet connection (not connected to internet), unable to upload events");
            } else if ([error code] == -1003) {
                AMPLITUDE_LOG(@"No internet connection (hostname not found), unable to upload events");
            } else if ([error code] == -1001) {
                AMPLITUDE_LOG(@"No internet connection (request timed out), unable to upload events");
            } else {
                NSLog(@"ERROR: Connection error:%@", error);
            }
        } else {
            NSLog(@"ERROR: response empty, error empty for NSURLConnection");
        }

        _updatingCurrently = NO;

        if (uploadSuccessful && [dbHelper getEventCount] > self.eventUploadThreshold) {
            int limit = _backoffUpload ? _backoffUploadBatchSize : 0;
            [self uploadEventsWithLimit:limit];

        } else if (_uploadTaskID != UIBackgroundTaskInvalid) {
            if (uploadSuccessful) {
                _backoffUpload = NO;
                _backoffUploadBatchSize = self.eventUploadMaxBatchSize;
            }

            // Upload finished, allow background task to be ended
            [[UIApplication sharedApplication] endBackgroundTask:_uploadTaskID];
            _uploadTaskID = UIBackgroundTaskInvalid;
        }
    }];
}

#pragma mark - application lifecycle methods

- (void)enterForeground
{
    [self updateLocation];

    NSNumber* now = [NSNumber numberWithLongLong:[[self currentTime] timeIntervalSince1970] * 1000];

    // Stop uploading
    if (_uploadTaskID != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:_uploadTaskID];
        _uploadTaskID = UIBackgroundTaskInvalid;
    }
    [self runOnBackgroundQueue:^{
        [self startOrContinueSession:now];
        _inForeground = YES;
        [self uploadEvents];
    }];
}

- (void)enterBackground
{
    NSNumber* now = [NSNumber numberWithLongLong:[[self currentTime] timeIntervalSince1970] * 1000];

    // Stop uploading
    if (_uploadTaskID != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:_uploadTaskID];
    }
    _uploadTaskID = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        //Took too long, manually stop
        if (_uploadTaskID != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:_uploadTaskID];
            _uploadTaskID = UIBackgroundTaskInvalid;
        }
    }];
    [self runOnBackgroundQueue:^{
        _inForeground = NO;
        [self refreshSessionTime:now];
        [self uploadEventsWithLimit:0];
    }];
}

#pragma mark - Sessions

/**
 * Creates a new session if we are in the background and
 * the current session is expired or if there is no current session ID].
 * Otherwise extends the session.
 *
 * Returns YES if a new session was created.
 */
- (BOOL)startOrContinueSession:(NSNumber*) timestamp
{
    if (!_inForeground) {
        if ([self inSession]) {
            if ([self isWithinMinTimeBetweenSessions:timestamp]) {
                [self refreshSessionTime:timestamp];
                return NO;
            }
            [self startNewSession:timestamp];
            return YES;
        }
        // no current session, check for previous session
        if ([self isWithinMinTimeBetweenSessions:timestamp]) {
            // extract session id
            long long previousSessionId = [self previousSessionId];
            if (previousSessionId == -1) {
                [self startNewSession:timestamp];
                return YES;
            }
            // extend previous session
            [self setSessionId:previousSessionId];
            [self refreshSessionTime:timestamp];
            return NO;
        } else {
            [self startNewSession:timestamp];
            return YES;
        }
    }
    // not creating a session means we should continue the session
    [self refreshSessionTime:timestamp];
    return NO;
}

- (void)startNewSession:(NSNumber*) timestamp
{
    if (_trackingSessionEvents) {
        [self sendSessionEvent:kAMPSessionEndEvent];
    }
    [self setSessionId:[timestamp longLongValue]];
    [self refreshSessionTime:timestamp];
    if (_trackingSessionEvents) {
        [self sendSessionEvent:kAMPSessionStartEvent];
    }
}

- (void)sendSessionEvent:(NSString*) sessionEvent
{
    if (_apiKey == nil) {
        NSLog(@"ERROR: apiKey cannot be nil or empty, set apiKey with initializeApiKey: before sending session event");
        return;
    }

    if (![self inSession]) {
        return;
    }

    NSMutableDictionary *apiProperties = [NSMutableDictionary dictionary];
    [apiProperties setValue:sessionEvent forKey:@"special"];
    NSNumber* timestamp = [self lastEventTime];
    [self logEvent:sessionEvent withEventProperties:nil withApiProperties:apiProperties withUserProperties:nil withTimestamp:timestamp outOfSession:NO];
}

- (BOOL)inSession
{
    return _sessionId >= 0;
}

- (BOOL)isWithinMinTimeBetweenSessions:(NSNumber*) timestamp
{
    NSNumber *previousSessionTime = [self lastEventTime];
    long long timeDelta = [timestamp longLongValue] - [previousSessionTime longLongValue];

    return timeDelta < self.minTimeBetweenSessionsMillis;
}

/**
 * Sets the session ID in memory and persists it to disk.
 */
- (void)setSessionId:(long long) timestamp
{
    _sessionId = timestamp;
    [self setPreviousSessionId:_sessionId];
}

/**
 * Update the session timer if there's a running session.
 */
- (void)refreshSessionTime:(NSNumber*) timestamp
{
    if (![self inSession]) {
        return;
    }
    [self setLastEventTime:timestamp];
}

- (void)setPreviousSessionId:(long long) previousSessionId
{
    NSNumber *value = [NSNumber numberWithLongLong:previousSessionId];
    [[AMPDatabaseHelper getDatabaseHelper:_instanceName] insertOrReplaceKeyLongValue:PREVIOUS_SESSION_ID value:value];
}

- (long long)previousSessionId
{
    NSNumber* previousSessionId = [[AMPDatabaseHelper getDatabaseHelper:_instanceName] getLongValue:PREVIOUS_SESSION_ID];
    if (previousSessionId == nil) {
        return -1;
    }
    return [previousSessionId longLongValue];
}

- (void)setLastEventTime:(NSNumber*) timestamp
{
    [[AMPDatabaseHelper getDatabaseHelper:_instanceName] insertOrReplaceKeyLongValue:PREVIOUS_SESSION_TIME value:timestamp];
}

- (NSNumber*)lastEventTime
{
    return [[AMPDatabaseHelper getDatabaseHelper:_instanceName] getLongValue:PREVIOUS_SESSION_TIME];
}

- (void)startSession
{
    return;
}

- (void)identify:(AMPIdentify *)identify
{
    if (identify == nil || [identify.userPropertyOperations count] == 0) {
        return;
    }
    [self logEvent:IDENTIFY_EVENT withEventProperties:nil withApiProperties:nil withUserProperties:identify.userPropertyOperations withTimestamp:nil outOfSession:NO];
}

#pragma mark - configurations

- (void)setUserProperties:(NSDictionary*) userProperties
{
    if (userProperties == nil || ![self isArgument:userProperties validType:[NSDictionary class] methodName:@"setUserProperties:"] || [userProperties count] == 0) {
        return;
    }

    NSDictionary *copy = [userProperties copy];
    [self runOnBackgroundQueue:^{
        AMPIdentify *identify = [AMPIdentify identify];
        for (NSString *key in copy) {
            NSObject *value = [copy objectForKey:key];
            [identify set:key value:value];
        }
        [self identify:identify];
    }];
}

// maintain for legacy
- (void)setUserProperties:(NSDictionary*) userProperties replace:(BOOL) replace
{
    [self setUserProperties:userProperties];
}

- (void)clearUserProperties
{
    AMPIdentify *identify = [[AMPIdentify identify] clearAll];
    [self identify:identify];
}

- (void)setUserId:(NSString*) userId
{
    if (!(userId == nil || [self isArgument:userId validType:[NSString class] methodName:@"setUserId:"])) {
        return;
    }

    [self runOnBackgroundQueue:^{
        SAFE_ARC_RETAIN(userId);
        SAFE_ARC_RELEASE(_userId);
        _userId = userId;
        [[AMPDatabaseHelper getDatabaseHelper:_instanceName] insertOrReplaceKeyValue:USER_ID value:_userId];
    }];
}

- (void)setOptOut:(BOOL)enabled
{
    [self runOnBackgroundQueue:^{
        NSNumber *value = [NSNumber numberWithBool:enabled];
        [[AMPDatabaseHelper getDatabaseHelper:_instanceName] insertOrReplaceKeyLongValue:OPT_OUT value:value];
    }];
}

- (void)setOffline:(BOOL)offline
{
    _offline = offline;

    if (!_offline) {
        [self uploadEvents];
    }
}

- (void)setEventUploadMaxBatchSize:(int) eventUploadMaxBatchSize
{
    _eventUploadMaxBatchSize = eventUploadMaxBatchSize;
    _backoffUploadBatchSize = eventUploadMaxBatchSize;
}

- (BOOL)optOut
{
    return [[[AMPDatabaseHelper getDatabaseHelper:_instanceName] getLongValue:OPT_OUT] boolValue];
}

- (void)setDeviceId:(NSString*)deviceId
{
    if (![self isValidDeviceId:deviceId]) {
        return;
    }

    [self runOnBackgroundQueue:^{
        SAFE_ARC_RETAIN(deviceId);
        SAFE_ARC_RELEASE(_deviceId);
        _deviceId = deviceId;
        [[AMPDatabaseHelper getDatabaseHelper:_instanceName] insertOrReplaceKeyValue:DEVICE_ID value:deviceId];
    }];
}

#pragma mark - location methods

- (void)updateLocation
{
    if (_locationListeningEnabled) {
        CLLocation *location = [_locationManager location];
        @synchronized (_locationManager) {
            if (location != nil) {
                (void) SAFE_ARC_RETAIN(location);
                SAFE_ARC_RELEASE(_lastKnownLocation);
                _lastKnownLocation = location;
            }
        }
    }
}

- (void)enableLocationListening
{
    _locationListeningEnabled = YES;
    [self updateLocation];
}

- (void)disableLocationListening
{
    _locationListeningEnabled = NO;
}

- (void)useAdvertisingIdForDeviceId
{
    _useAdvertisingIdForDeviceId = YES;
}

#pragma mark - Getters for device data
- (NSString*) getDeviceId
{
    return _deviceId;
}

- (NSString*) initializeDeviceId
{
    if (_deviceId == nil) {
        AMPDatabaseHelper *dbHelper = [AMPDatabaseHelper getDatabaseHelper:_instanceName];
        _deviceId = SAFE_ARC_RETAIN([dbHelper getValue:DEVICE_ID]);
        if (![self isValidDeviceId:_deviceId]) {
            NSString *newDeviceId = SAFE_ARC_RETAIN([self _getDeviceId]);
            SAFE_ARC_RELEASE(_deviceId);
            _deviceId = newDeviceId;
            [dbHelper insertOrReplaceKeyValue:DEVICE_ID value:newDeviceId];
        }
    }
    return _deviceId;
}

- (NSString*)_getDeviceId
{
    NSString *deviceId = nil;
    if (_useAdvertisingIdForDeviceId) {
        deviceId = _deviceInfo.advertiserID;
    }

    // return identifierForVendor
    if (!deviceId) {
        deviceId = _deviceInfo.vendorID;
    }

    if (!deviceId) {
        // Otherwise generate random ID
        deviceId = _deviceInfo.generateUUID;
    }
    return SAFE_ARC_AUTORELEASE([[NSString alloc] initWithString:deviceId]);
}

- (BOOL)isValidDeviceId:(NSString*)deviceId
{
    if (deviceId == nil ||
        ![self isArgument:deviceId validType:[NSString class] methodName:@"isValidDeviceId"] ||
        [deviceId isEqualToString:@"e3f5536a141811db40efd6400f1d0a4e"] ||
        [deviceId isEqualToString:@"04bab7ee75b9a58d39b8dc54e8851084"]) {
        return NO;
    }
    return YES;
}

- (NSDictionary*)replaceWithEmptyJSON:(NSDictionary*) dictionary
{
    return dictionary == nil ? [NSMutableDictionary dictionary] : dictionary;
}

- (id) truncate:(id) obj
{
    if ([obj isKindOfClass:[NSString class]]) {
        obj = (NSString*)obj;
        if ([obj length] > kAMPMaxStringLength) {
            obj = [obj substringToIndex:kAMPMaxStringLength];
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *arr = [NSMutableArray array];
        id objCopy = [obj copy];
        for (id i in objCopy) {
            [arr addObject:[self truncate:i]];
        }
        SAFE_ARC_RELEASE(objCopy);
        obj = [NSArray arrayWithArray:arr];
    } else if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        id objCopy = [obj copy];
        for (id key in objCopy) {
            NSString *coercedKey;
            if (![key isKindOfClass:[NSString class]]) {
                coercedKey = [key description];
                NSLog(@"WARNING: Non-string property key, received %@, coercing to %@", [key class], coercedKey);
            } else {
                coercedKey = key;
            }
            dict[coercedKey] = [self truncate:objCopy[key]];
        }
        SAFE_ARC_RELEASE(objCopy);
        obj = [NSDictionary dictionaryWithDictionary:dict];
    }
    return obj;
}

- (BOOL)isArgument:(id) argument validType:(Class) class methodName:(NSString*) methodName
{
    if ([argument isKindOfClass:class]) {
        return YES;
    } else {
        NSLog(@"ERROR: Invalid type argument to method %@, expected %@, received %@, ", methodName, class, [argument class]);
        return NO;
    }
}

- (NSString*)md5HexDigest:(NSString*)input
{
    const char* str = [input UTF8String];
    unsigned char result[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, (CC_LONG) strlen(str), result);

    NSMutableString *ret = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH*2];
    for(int i = 0; i<CC_MD5_DIGEST_LENGTH; i++) {
        [ret appendFormat:@"%02x",result[i]];
    }
    return ret;
}

- (NSString*)urlEncodeString:(NSString*) string
{
    NSString *newString;
#if __has_feature(objc_arc)
    newString = (__bridge_transfer NSString*)
    CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,
                                            (__bridge CFStringRef)string,
                                            NULL,
                                            CFSTR(":/?#[]@!$ &'()*+,;=\"<>%{}|\\^~`"),
                                            CFStringConvertNSStringEncodingToEncoding(NSUTF8StringEncoding));
#else
    newString = NSMakeCollectable(CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,
                                                                          (CFStringRef)string,
                                                                          NULL,
                                                                          CFSTR(":/?#[]@!$ &'()*+,;=\"<>%{}|\\^~`"),
                                                                          CFStringConvertNSStringEncodingToEncoding(NSUTF8StringEncoding)));
    SAFE_ARC_AUTORELEASE(newString);
#endif
    if (newString) {
        return newString;
    }
    return @"";
}

- (NSDate*) currentTime
{
    return [NSDate date];
}

- (void)printEventsCount
{
    NSLog(@"Events count:%ld", (long) [[AMPDatabaseHelper getDatabaseHelper:_instanceName] getEventCount]);
}

#pragma mark - Compatibility


/**
 * Move all preference data from the legacy name to the new, static name if needed.
 *
 * Data used to be in the NSCachesDirectory, which would sometimes be cleared unexpectedly,
 * resulting in data loss. We move the data from NSCachesDirectory to the current
 * location in NSLibraryDirectory.
 *
 */
- (BOOL)upgradePrefs
{
    // Copy any old data files to new file paths
    NSString *oldEventsDataDirectory = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex: 0];
    NSString *oldPropertyListPath = [oldEventsDataDirectory stringByAppendingPathComponent:@"com.amplitude.plist"];
    NSString *oldEventsDataPath = [oldEventsDataDirectory stringByAppendingPathComponent:@"com.amplitude.archiveDict"];
    BOOL success = [self moveFileIfNotExists:oldPropertyListPath to:_propertyListPath];
    success &= [self moveFileIfNotExists:oldEventsDataPath to:_eventsDataPath];
    return success;
}

#pragma mark - Filesystem

- (BOOL)savePropertyList {
    @synchronized (_propertyList) {
        BOOL success = [self serializePList:_propertyList toFile:_propertyListPath];
        if (!success) {
            NSLog(@"Error: Unable to save propertyList to file");
        }
        return success;
    }
}

- (id)deserializePList:(NSString*)path {
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSData *pListData = [[NSFileManager defaultManager] contentsAtPath:path];
        if (pListData != nil) {
            NSError *error = nil;
            NSMutableDictionary *pList = (NSMutableDictionary *)[NSPropertyListSerialization
                                                                   propertyListWithData:pListData
                                                                   options:NSPropertyListMutableContainersAndLeaves
                                                                   format:NULL error:&error];
            if (error == nil) {
                return pList;
            } else {
                NSLog(@"ERROR: propertyList deserialization error:%@", error);
                error = nil;
                [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
                if (error != nil) {
                    NSLog(@"ERROR: Can't remove corrupt propertyList file:%@", error);
                }
            }
        }
    }
    return nil;
}

- (BOOL)serializePList:(id)data toFile:(NSString*)path {
    NSError *error = nil;
    NSData *propertyListData = [NSPropertyListSerialization
                                dataWithPropertyList:data
                                format:NSPropertyListXMLFormat_v1_0
                                options:0 error:&error];
    if (error == nil) {
        if (propertyListData != nil) {
            BOOL success = [propertyListData writeToFile:path atomically:YES];
            if (!success) {
                NSLog(@"ERROR: Unable to save propertyList to file");
            }
            return success;
        } else {
            NSLog(@"ERROR: propertyListData is nil");
        }
    } else {
        NSLog(@"ERROR: Unable to serialize propertyList:%@", error);
    }
    return NO;

}

- (id)unarchive:(NSString*)path {
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        @try {
            id data = [NSKeyedUnarchiver unarchiveObjectWithFile:path];
            return data;
        }
        @catch (NSException *e) {
            NSLog(@"EXCEPTION: Corrupt file %@: %@", [e name], [e reason]);
            NSError *error = nil;
            [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
            if (error != nil) {
                NSLog(@"ERROR: Can't remove corrupt archiveDict file:%@", error);
            }
        }
    }
    return nil;
}

- (BOOL)archive:(id) obj toFile:(NSString*)path {
    return [NSKeyedArchiver archiveRootObject:obj toFile:path];
}

- (BOOL)moveFileIfNotExists:(NSString*)from to:(NSString*)to
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error;
    if (![fileManager fileExistsAtPath:to] &&
        [fileManager fileExistsAtPath:from]) {
        if ([fileManager copyItemAtPath:from toPath:to error:&error]) {
            AMPLITUDE_LOG(@"INFO: copied %@ to %@", from, to);
            [fileManager removeItemAtPath:from error:NULL];
        } else {
            AMPLITUDE_LOG(@"WARN: Copy from %@ to %@ failed: %@", from, to, error);
            return NO;
        }
    }
    return YES;
}

#pragma clang diagnostic pop
@end
