// Simulator side of the BLE bridge, injected with DYLD_INSERT_LIBRARIES.
// Every CBCentralManager the app allocates becomes an SBCentralManager that forwards to the
// Mac helper over 127.0.0.1; peripherals, services and characteristics are local stand-ins
// whose state is filled from helper events. Nothing here is linked into the app.

#import <CoreBluetooth/CoreBluetooth.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <sys/socket.h>
#import <unistd.h>

#define SBLog(format, ...) NSLog(@"[SimBLE] " format, ##__VA_ARGS__)

@class SBCentralManager;

// Fake CB objects must never deallocate: CBPeripheral is created without its private
// initializer, so its own dealloc must not run on an object it never set up.
static NSMutableArray *SBImmortalObjects(void) {
    static NSMutableArray *objects;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        objects = [NSMutableArray array];
    });
    return objects;
}

static void SBKeepAlive(id object) {
    @synchronized(SBImmortalObjects()) {
        [SBImmortalObjects() addObject:object];
    }
}

static NSError *SBDecodeError(id value) {
    if (![value isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSDictionary *error = value;
    return [NSError errorWithDomain:error[@"domain"] ?: CBErrorDomain
                               code:[error[@"code"] integerValue]
                           userInfo:@{NSLocalizedDescriptionKey: error[@"message"] ?: @""}];
}

static NSArray<NSString *> *SBUUIDStrings(NSArray<CBUUID *> *uuids) {
    if (uuids == nil) {
        return nil;
    }
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    for (CBUUID *uuid in uuids) {
        [strings addObject:uuid.UUIDString];
    }
    return strings;
}

static NSArray<CBUUID *> *SBUUIDs(id strings) {
    NSMutableArray<CBUUID *> *uuids = [NSMutableArray array];
    if ([strings isKindOfClass:[NSArray class]]) {
        for (NSString *string in strings) {
            [uuids addObject:[CBUUID UUIDWithString:string]];
        }
    }
    return uuids;
}

static NSData *SBData(id base64) {
    return [base64 isKindOfClass:[NSString class]] ? [[NSData alloc] initWithBase64EncodedString:base64 options:0] : nil;
}

#pragma mark - Link

// One TCP connection to the helper, reconnecting every second while the helper is down.
@interface SBBridgeLink : NSObject
@property (nonatomic, copy) void (^onMessage)(NSDictionary *message);
@property (nonatomic, copy) void (^onStatus)(BOOL connected);
- (void)start;
- (void)send:(NSDictionary *)message;
- (void)close;
@end

@implementation SBBridgeLink {
    int _socket;
    BOOL _closed;
    dispatch_queue_t _writeQueue;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _socket = -1;
        _writeQueue = dispatch_queue_create("sim-ble-shim.write", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)start {
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        [self runLoop];
    }];
    thread.name = @"sim-ble-shim.read";
    [thread start];
}

- (void)runLoop {
    const char *portValue = getenv("SIM_BLE_BRIDGE_PORT");
    uint16_t port = portValue ? (uint16_t)atoi(portValue) : 50505;
    BOOL reportedDown = NO;

    while (!_closed) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in address = {0};
        address.sin_len = sizeof(address);
        address.sin_family = AF_INET;
        address.sin_port = htons(port);
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
            close(fd);
            if (!reportedDown) {
                reportedDown = YES;
                SBLog(@"SimBLE not reachable on 127.0.0.1:%u, retrying every second", port);
                self.onStatus(NO);
            }
            sleep(1);
            continue;
        }
        int enabled = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &enabled, sizeof(enabled));
        @synchronized(self) {
            _socket = fd;
        }
        reportedDown = NO;
        SBLog(@"connected to SimBLE");
        // Identifies this central's session in the Mac app's logs; always the first message on the link.
        NSProcessInfo *processInfo = NSProcessInfo.processInfo;
        [self send:@{
            @"op": @"register",
            @"bundleId": NSBundle.mainBundle.bundleIdentifier ?: processInfo.processName,
            @"udid": processInfo.environment[@"SIMULATOR_UDID"] ?: @"",
            @"pid": @(processInfo.processIdentifier),
        }];
        self.onStatus(YES);

        NSMutableData *buffer = [NSMutableData data];
        uint8_t chunk[65536];
        ssize_t count;
        while ((count = recv(fd, chunk, sizeof(chunk), 0)) > 0) {
            [buffer appendBytes:chunk length:(NSUInteger)count];
            while (YES) {
                NSRange newline = [buffer rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, buffer.length)];
                if (newline.location == NSNotFound) {
                    break;
                }
                NSData *line = [buffer subdataWithRange:NSMakeRange(0, newline.location)];
                [buffer replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
                id message = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
                if ([message isKindOfClass:[NSDictionary class]]) {
                    self.onMessage(message);
                }
            }
        }

        @synchronized(self) {
            _socket = -1;
        }
        close(fd);
        if (!_closed) {
            SBLog(@"SimBLE connection lost");
            reportedDown = YES;
            self.onStatus(NO);
        }
    }
}

- (void)send:(NSDictionary *)message {
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:message options:0 error:nil] mutableCopy];
    [data appendBytes:"\n" length:1];
    dispatch_async(_writeQueue, ^{
        int fd;
        @synchronized(self) {
            fd = self->_socket;
        }
        if (fd < 0) {
            SBLog(@"dropped %@ while helper is not connected", message[@"op"]);
            return;
        }
        const uint8_t *bytes = data.bytes;
        size_t remaining = data.length;
        while (remaining > 0) {
            ssize_t sent = send(fd, bytes, remaining, 0);
            if (sent <= 0) {
                return;
            }
            bytes += sent;
            remaining -= (size_t)sent;
        }
    });
}

- (void)close {
    _closed = YES;
    @synchronized(self) {
        if (_socket >= 0) {
            shutdown(_socket, SHUT_RDWR);
        }
    }
}

@end

#pragma mark - Attributes

@interface SBCharacteristic : CBMutableCharacteristic
@property (nonatomic, weak) CBService *sb_service;
@property (nonatomic, copy) NSData *sb_value;
@property (nonatomic) BOOL sb_notifying;
@end

@implementation SBCharacteristic

- (CBService *)service {
    return self.sb_service;
}

- (NSData *)value {
    return self.sb_value;
}

- (BOOL)isNotifying {
    return self.sb_notifying;
}

- (NSArray<CBDescriptor *> *)descriptors {
    return @[];
}

@end

@interface SBService : CBMutableService
@property (nonatomic, weak) CBPeripheral *sb_peripheral;
@property (nonatomic, copy) NSArray<SBCharacteristic *> *sb_characteristics;
@end

@implementation SBService

- (CBPeripheral *)peripheral {
    return self.sb_peripheral;
}

- (NSArray<CBCharacteristic *> *)characteristics {
    return self.sb_characteristics;
}

- (NSArray<CBService *> *)includedServices {
    return @[];
}

- (SBCharacteristic *)sb_characteristicWithUUID:(NSString *)uuid {
    CBUUID *target = [CBUUID UUIDWithString:uuid];
    for (SBCharacteristic *characteristic in self.sb_characteristics) {
        if ([characteristic.UUID isEqual:target]) {
            return characteristic;
        }
    }
    return nil;
}

@end

#pragma mark - Peripheral

@interface SBCentralManager : CBCentralManager
- (void)sb_send:(NSDictionary *)message;
- (void)sb_perform:(dispatch_block_t)block;
@end

@interface SBPeripheral : CBPeripheral
@property (nonatomic, strong) NSUUID *sb_identifier;
@property (nonatomic, copy) NSString *sb_name;
@property (nonatomic) CBPeripheralState sb_state;
@property (nonatomic, copy) NSArray<SBService *> *sb_services;
@property (nonatomic, weak) id<CBPeripheralDelegate> sb_delegate;
@property (nonatomic, weak) SBCentralManager *sb_central;
@property (nonatomic) NSUInteger sb_mtuWithResponse;
@property (nonatomic) NSUInteger sb_mtuWithoutResponse;
@end

@implementation SBPeripheral

+ (SBPeripheral *)sb_peripheralWithIdentifier:(NSUUID *)identifier central:(SBCentralManager *)central {
    // CBPeripheral has no public initializer; every property the app reads is overridden below.
    SBPeripheral *peripheral = [self alloc];
    peripheral.sb_identifier = identifier;
    peripheral.sb_central = central;
    peripheral.sb_mtuWithResponse = 512;
    peripheral.sb_mtuWithoutResponse = 20;
    SBKeepAlive(peripheral);
    return peripheral;
}

- (NSUUID *)identifier {
    return self.sb_identifier;
}

- (NSString *)name {
    return self.sb_name;
}

- (CBPeripheralState)state {
    return self.sb_state;
}

- (NSArray<CBService *> *)services {
    return self.sb_services;
}

- (id<CBPeripheralDelegate>)delegate {
    return self.sb_delegate;
}

- (void)setDelegate:(id<CBPeripheralDelegate>)delegate {
    self.sb_delegate = delegate;
}

- (BOOL)canSendWriteWithoutResponse {
    // The helper queues writes without response against the Mac peripheral's flow control.
    return YES;
}

- (BOOL)ancsAuthorized {
    return NO;
}

- (NSNumber *)RSSI {
    return nil;
}

- (BOOL)isEqual:(id)object {
    return self == object;
}

- (NSUInteger)hash {
    return self.sb_identifier.hash;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<SimBLEPeripheral %@ %@ state=%ld>", self.sb_identifier.UUIDString, self.sb_name, (long)self.sb_state];
}

- (NSUInteger)maximumWriteValueLengthForType:(CBCharacteristicWriteType)type {
    return type == CBCharacteristicWriteWithResponse ? self.sb_mtuWithResponse : self.sb_mtuWithoutResponse;
}

- (void)sb_send:(NSString *)operation fields:(NSDictionary *)fields {
    NSMutableDictionary *message = [fields mutableCopy];
    message[@"op"] = operation;
    message[@"id"] = self.sb_identifier.UUIDString;
    [self.sb_central sb_send:message];
}

- (NSDictionary *)sb_fieldsForCharacteristic:(CBCharacteristic *)characteristic {
    return @{@"service": characteristic.service.UUID.UUIDString ?: @"", @"char": characteristic.UUID.UUIDString};
}

- (void)readRSSI {
    [self sb_send:@"readRSSI" fields:@{}];
}

- (void)discoverServices:(NSArray<CBUUID *> *)serviceUUIDs {
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    fields[@"services"] = SBUUIDStrings(serviceUUIDs);
    [self sb_send:@"discoverServices" fields:fields];
}

- (void)discoverIncludedServices:(NSArray<CBUUID *> *)includedServiceUUIDs forService:(CBService *)service {
    [self.sb_central sb_perform:^{
        if ([self.sb_delegate respondsToSelector:@selector(peripheral:didDiscoverIncludedServicesForService:error:)]) {
            [self.sb_delegate peripheral:self didDiscoverIncludedServicesForService:service error:nil];
        }
    }];
}

- (void)discoverCharacteristics:(NSArray<CBUUID *> *)characteristicUUIDs forService:(CBService *)service {
    NSMutableDictionary *fields = [NSMutableDictionary dictionaryWithObject:service.UUID.UUIDString forKey:@"service"];
    fields[@"chars"] = SBUUIDStrings(characteristicUUIDs);
    [self sb_send:@"discoverCharacteristics" fields:fields];
}

- (void)discoverDescriptorsForCharacteristic:(CBCharacteristic *)characteristic {
    // Descriptors are not bridged; CCCD handling happens on the Mac through setNotifyValue.
    [self.sb_central sb_perform:^{
        if ([self.sb_delegate respondsToSelector:@selector(peripheral:didDiscoverDescriptorsForCharacteristic:error:)]) {
            [self.sb_delegate peripheral:self didDiscoverDescriptorsForCharacteristic:characteristic error:nil];
        }
    }];
}

- (void)readValueForCharacteristic:(CBCharacteristic *)characteristic {
    [self sb_send:@"read" fields:[self sb_fieldsForCharacteristic:characteristic]];
}

- (void)writeValue:(NSData *)data forCharacteristic:(CBCharacteristic *)characteristic type:(CBCharacteristicWriteType)type {
    NSMutableDictionary *fields = [[self sb_fieldsForCharacteristic:characteristic] mutableCopy];
    fields[@"data"] = [data base64EncodedStringWithOptions:0];
    fields[@"withResponse"] = @(type == CBCharacteristicWriteWithResponse);
    [self sb_send:@"write" fields:fields];
}

- (void)setNotifyValue:(BOOL)enabled forCharacteristic:(CBCharacteristic *)characteristic {
    NSMutableDictionary *fields = [[self sb_fieldsForCharacteristic:characteristic] mutableCopy];
    fields[@"enabled"] = @(enabled);
    [self sb_send:@"notify" fields:fields];
}

- (void)readValueForDescriptor:(CBDescriptor *)descriptor {
    SBLog(@"descriptor reads are not bridged");
}

- (void)writeValue:(NSData *)data forDescriptor:(CBDescriptor *)descriptor {
    SBLog(@"descriptor writes are not bridged");
}

- (void)openL2CAPChannel:(CBL2CAPPSM)PSM {
    [self.sb_central sb_perform:^{
        if ([self.sb_delegate respondsToSelector:@selector(peripheral:didOpenL2CAPChannel:error:)]) {
            NSError *error = [NSError errorWithDomain:CBErrorDomain code:CBErrorOperationNotSupported userInfo:@{NSLocalizedDescriptionKey: @"L2CAP is not bridged"}];
            [self.sb_delegate peripheral:self didOpenL2CAPChannel:nil error:error];
        }
    }];
}

- (SBService *)sb_serviceWithUUID:(NSString *)uuid {
    CBUUID *target = [CBUUID UUIDWithString:uuid];
    for (SBService *service in self.sb_services) {
        if ([service.UUID isEqual:target]) {
            return service;
        }
    }
    return nil;
}

@end

#pragma mark - Central

@implementation SBCentralManager {
    __weak id<CBCentralManagerDelegate> _sbDelegate;
    dispatch_queue_t _sbQueue;
    CBManagerState _sbState;
    BOOL _sbScanning;
    SBBridgeLink *_sbLink;
    NSMutableDictionary<NSUUID *, SBPeripheral *> *_sbPeripherals;
    NSMutableDictionary<NSNumber *, dispatch_semaphore_t> *_sbPendingRequests;
    NSMutableDictionary<NSNumber *, NSDictionary *> *_sbResponses;
    NSInteger _sbNextRequest;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"
- (instancetype)initWithDelegate:(id<CBCentralManagerDelegate>)delegate queue:(dispatch_queue_t)queue options:(NSDictionary<NSString *, id> *)options {
    // The real initializer runs without a delegate so the simulator's "unsupported" state never reaches the app.
    self = [super initWithDelegate:nil queue:queue options:nil];
    if (self) {
        _sbDelegate = delegate;
        _sbQueue = queue ?: dispatch_get_main_queue();
        _sbState = CBManagerStateUnknown;
        _sbPeripherals = [NSMutableDictionary dictionary];
        _sbPendingRequests = [NSMutableDictionary dictionary];
        _sbResponses = [NSMutableDictionary dictionary];
        _sbLink = [[SBBridgeLink alloc] init];
        __weak SBCentralManager *weakSelf = self;
        _sbLink.onMessage = ^(NSDictionary *message) {
            [weakSelf sb_receive:message];
        };
        _sbLink.onStatus = ^(BOOL connected) {
            [weakSelf sb_linkChanged:connected];
        };
        [_sbLink start];
    }
    return self;
}
#pragma clang diagnostic pop

- (void)dealloc {
    [_sbLink close];
}

- (id<CBCentralManagerDelegate>)delegate {
    return _sbDelegate;
}

- (void)setDelegate:(id<CBCentralManagerDelegate>)delegate {
    _sbDelegate = delegate;
}

- (CBManagerState)state {
    return _sbState;
}

- (CBManagerAuthorization)authorization {
    return CBManagerAuthorizationAllowedAlways;
}

- (BOOL)isScanning {
    return _sbScanning;
}

+ (BOOL)supportsFeatures:(CBCentralManagerFeature)features {
    return NO;
}

- (void)sb_send:(NSDictionary *)message {
    [_sbLink send:message];
}

- (void)sb_perform:(dispatch_block_t)block {
    dispatch_async(_sbQueue, block);
}

- (void)scanForPeripheralsWithServices:(NSArray<CBUUID *> *)serviceUUIDs options:(NSDictionary<NSString *, id> *)options {
    _sbScanning = YES;
    NSMutableDictionary *message = [NSMutableDictionary dictionaryWithObject:@"scan" forKey:@"op"];
    message[@"services"] = SBUUIDStrings(serviceUUIDs);
    message[@"allowDuplicates"] = @([options[CBCentralManagerScanOptionAllowDuplicatesKey] boolValue]);
    [self sb_send:message];
}

- (void)stopScan {
    _sbScanning = NO;
    [self sb_send:@{@"op": @"stopScan"}];
}

- (void)connectPeripheral:(CBPeripheral *)peripheral options:(NSDictionary<NSString *, id> *)options {
    if ([peripheral isKindOfClass:[SBPeripheral class]]) {
        ((SBPeripheral *)peripheral).sb_state = CBPeripheralStateConnecting;
    }
    [self sb_send:@{@"op": @"connect", @"id": peripheral.identifier.UUIDString}];
}

- (void)cancelPeripheralConnection:(CBPeripheral *)peripheral {
    if ([peripheral isKindOfClass:[SBPeripheral class]] && peripheral.state != CBPeripheralStateDisconnected) {
        ((SBPeripheral *)peripheral).sb_state = CBPeripheralStateDisconnecting;
    }
    [self sb_send:@{@"op": @"disconnect", @"id": peripheral.identifier.UUIDString}];
}

- (NSArray<CBPeripheral *> *)retrievePeripheralsWithIdentifiers:(NSArray<NSUUID *> *)identifiers {
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    for (NSUUID *identifier in identifiers) {
        [strings addObject:identifier.UUIDString];
    }
    return [self sb_peripheralsFromResponse:[self sb_request:@{@"op": @"retrieve", @"ids": strings}]];
}

- (NSArray<CBPeripheral *> *)retrieveConnectedPeripheralsWithServices:(NSArray<CBUUID *> *)serviceUUIDs {
    return [self sb_peripheralsFromResponse:[self sb_request:@{@"op": @"retrieveConnected", @"services": SBUUIDStrings(serviceUUIDs) ?: @[]}]];
}

- (void)registerForConnectionEventsWithOptions:(NSDictionary<CBConnectionEventMatchingOption, id> *)options {
}

#pragma mark Bridge

// Blocks the caller until the helper answers, like the synchronous CoreBluetooth retrieve APIs.
// Responses are resolved on the link's read thread, so waiting on the delegate queue is safe.
- (NSDictionary *)sb_request:(NSDictionary *)command {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSNumber *requestID;
    @synchronized(_sbPendingRequests) {
        requestID = @(++_sbNextRequest);
        _sbPendingRequests[requestID] = semaphore;
    }
    NSMutableDictionary *message = [command mutableCopy];
    message[@"req"] = requestID;
    [self sb_send:message];
    long timedOut = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    @synchronized(_sbPendingRequests) {
        [_sbPendingRequests removeObjectForKey:requestID];
        NSDictionary *response = _sbResponses[requestID];
        [_sbResponses removeObjectForKey:requestID];
        if (timedOut) {
            SBLog(@"%@ timed out", command[@"op"]);
        }
        return response;
    }
}

- (NSArray<CBPeripheral *> *)sb_peripheralsFromResponse:(NSDictionary *)response {
    NSMutableArray<CBPeripheral *> *result = [NSMutableArray array];
    for (NSDictionary *entry in response[@"peripherals"]) {
        SBPeripheral *peripheral = [self sb_peripheralWithID:entry[@"id"]];
        if (peripheral == nil) {
            continue;
        }
        if ([entry[@"name"] isKindOfClass:[NSString class]]) {
            peripheral.sb_name = entry[@"name"];
        }
        [result addObject:peripheral];
    }
    return result;
}

- (SBPeripheral *)sb_peripheralWithID:(NSString *)string {
    NSUUID *identifier = [string isKindOfClass:[NSString class]] ? [[NSUUID alloc] initWithUUIDString:string] : nil;
    if (identifier == nil) {
        return nil;
    }
    @synchronized(_sbPeripherals) {
        SBPeripheral *peripheral = _sbPeripherals[identifier];
        if (peripheral == nil) {
            peripheral = [SBPeripheral sb_peripheralWithIdentifier:identifier central:self];
            _sbPeripherals[identifier] = peripheral;
        }
        return peripheral;
    }
}

- (void)sb_receive:(NSDictionary *)message {
    NSNumber *requestID = message[@"re"];
    if (requestID != nil) {
        @synchronized(_sbPendingRequests) {
            dispatch_semaphore_t semaphore = _sbPendingRequests[requestID];
            if (semaphore != nil) {
                _sbResponses[requestID] = message;
                dispatch_semaphore_signal(semaphore);
            }
        }
        return;
    }
    dispatch_async(_sbQueue, ^{
        [self sb_handleEvent:message];
    });
}

- (void)sb_linkChanged:(BOOL)connected {
    if (connected) {
        return; // The helper reports the Mac central state right after accepting.
    }
    dispatch_async(_sbQueue, ^{
        // The helper drops every connection of a closed session; mirror that before reporting power off.
        NSArray<SBPeripheral *> *peripherals;
        @synchronized(self->_sbPeripherals) {
            peripherals = self->_sbPeripherals.allValues;
        }
        NSError *error = [NSError errorWithDomain:CBErrorDomain code:CBErrorConnectionFailed userInfo:@{NSLocalizedDescriptionKey: @"Simulator BLE bridge helper disconnected"}];
        for (SBPeripheral *peripheral in peripherals) {
            if (peripheral.sb_state != CBPeripheralStateDisconnected) {
                [self sb_markDisconnected:peripheral error:error];
            }
        }
        self->_sbScanning = NO;
        [self sb_updateState:CBManagerStatePoweredOff];
    });
}

- (void)sb_updateState:(CBManagerState)state {
    if (_sbState == state) {
        return;
    }
    _sbState = state;
    [_sbDelegate centralManagerDidUpdateState:self];
}

- (void)sb_markDisconnected:(SBPeripheral *)peripheral error:(NSError *)error {
    peripheral.sb_state = CBPeripheralStateDisconnected;
    for (SBService *service in peripheral.sb_services) {
        for (SBCharacteristic *characteristic in service.sb_characteristics) {
            characteristic.sb_notifying = NO;
        }
    }
    id<CBCentralManagerDelegate> delegate = _sbDelegate;
    if ([delegate respondsToSelector:@selector(centralManager:didDisconnectPeripheral:timestamp:isReconnecting:error:)]) {
        [delegate centralManager:self didDisconnectPeripheral:peripheral timestamp:CFAbsoluteTimeGetCurrent() isReconnecting:NO error:error];
    } else if ([delegate respondsToSelector:@selector(centralManager:didDisconnectPeripheral:error:)]) {
        [delegate centralManager:self didDisconnectPeripheral:peripheral error:error];
    }
}

- (NSDictionary<NSString *, id> *)sb_advertisementData:(NSDictionary *)encoded {
    NSMutableDictionary<NSString *, id> *data = [NSMutableDictionary dictionary];
    if ([encoded[@"localName"] isKindOfClass:[NSString class]]) {
        data[CBAdvertisementDataLocalNameKey] = encoded[@"localName"];
    }
    data[CBAdvertisementDataManufacturerDataKey] = SBData(encoded[@"manufacturerData"]);
    if (encoded[@"serviceUUIDs"] != nil) {
        data[CBAdvertisementDataServiceUUIDsKey] = SBUUIDs(encoded[@"serviceUUIDs"]);
    }
    if (encoded[@"overflowServiceUUIDs"] != nil) {
        data[CBAdvertisementDataOverflowServiceUUIDsKey] = SBUUIDs(encoded[@"overflowServiceUUIDs"]);
    }
    if (encoded[@"solicitedServiceUUIDs"] != nil) {
        data[CBAdvertisementDataSolicitedServiceUUIDsKey] = SBUUIDs(encoded[@"solicitedServiceUUIDs"]);
    }
    if ([encoded[@"serviceData"] isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary<CBUUID *, NSData *> *serviceData = [NSMutableDictionary dictionary];
        [encoded[@"serviceData"] enumerateKeysAndObjectsUsingBlock:^(NSString *uuid, NSString *value, BOOL *stop) {
            serviceData[[CBUUID UUIDWithString:uuid]] = SBData(value);
        }];
        data[CBAdvertisementDataServiceDataKey] = serviceData;
    }
    data[CBAdvertisementDataTxPowerLevelKey] = encoded[@"txPower"];
    data[CBAdvertisementDataIsConnectable] = encoded[@"isConnectable"];
    return data;
}

// Runs on the delegate queue; mutates the stand-in objects before calling the delegate, as CoreBluetooth does.
- (void)sb_handleEvent:(NSDictionary *)message {
    NSString *event = message[@"ev"];
    NSError *error = SBDecodeError(message[@"error"]);
    SBPeripheral *peripheral = [self sb_peripheralWithID:message[@"id"]];
    id<CBCentralManagerDelegate> delegate = _sbDelegate;
    id<CBPeripheralDelegate> peripheralDelegate = peripheral.sb_delegate;
    if (message[@"mtuWithout"] != nil) {
        peripheral.sb_mtuWithResponse = [message[@"mtuWith"] unsignedIntegerValue];
        peripheral.sb_mtuWithoutResponse = [message[@"mtuWithout"] unsignedIntegerValue];
    }

    if ([event isEqualToString:@"state"]) {
        [self sb_updateState:(CBManagerState)[message[@"state"] integerValue]];
    } else if ([event isEqualToString:@"discovered"]) {
        if (!_sbScanning || peripheral == nil) {
            return;
        }
        if ([message[@"name"] isKindOfClass:[NSString class]]) {
            peripheral.sb_name = message[@"name"];
        } else if ([message[@"adv"][@"localName"] isKindOfClass:[NSString class]] && peripheral.sb_name == nil) {
            peripheral.sb_name = message[@"adv"][@"localName"];
        }
        if ([delegate respondsToSelector:@selector(centralManager:didDiscoverPeripheral:advertisementData:RSSI:)]) {
            [delegate centralManager:self didDiscoverPeripheral:peripheral advertisementData:[self sb_advertisementData:message[@"adv"]] RSSI:message[@"rssi"]];
        }
    } else if ([event isEqualToString:@"connected"]) {
        peripheral.sb_state = CBPeripheralStateConnected;
        if ([delegate respondsToSelector:@selector(centralManager:didConnectPeripheral:)]) {
            [delegate centralManager:self didConnectPeripheral:peripheral];
        }
    } else if ([event isEqualToString:@"failToConnect"]) {
        if (peripheral == nil) {
            return;
        }
        peripheral.sb_state = CBPeripheralStateDisconnected;
        if ([delegate respondsToSelector:@selector(centralManager:didFailToConnectPeripheral:error:)]) {
            [delegate centralManager:self didFailToConnectPeripheral:peripheral error:error];
        }
    } else if ([event isEqualToString:@"disconnected"]) {
        if (peripheral != nil) {
            [self sb_markDisconnected:peripheral error:error];
        }
    } else if ([event isEqualToString:@"name"]) {
        peripheral.sb_name = [message[@"name"] isKindOfClass:[NSString class]] ? message[@"name"] : nil;
        if ([peripheralDelegate respondsToSelector:@selector(peripheralDidUpdateName:)]) {
            [peripheralDelegate peripheralDidUpdateName:peripheral];
        }
    } else if ([event isEqualToString:@"services"]) {
        // Existing stand-ins are reused so references the app already holds stay valid.
        NSMutableArray<SBService *> *services = [NSMutableArray array];
        for (CBUUID *uuid in SBUUIDs(message[@"services"])) {
            SBService *service = [peripheral sb_serviceWithUUID:uuid.UUIDString];
            if (service == nil) {
                service = [[SBService alloc] initWithType:uuid primary:YES];
                service.sb_peripheral = peripheral;
                SBKeepAlive(service);
            }
            [services addObject:service];
        }
        peripheral.sb_services = services;
        if ([peripheralDelegate respondsToSelector:@selector(peripheral:didDiscoverServices:)]) {
            [peripheralDelegate peripheral:peripheral didDiscoverServices:error];
        }
    } else if ([event isEqualToString:@"characteristics"]) {
        SBService *service = [peripheral sb_serviceWithUUID:message[@"service"]];
        if (service == nil) {
            return;
        }
        NSMutableArray<SBCharacteristic *> *characteristics = [NSMutableArray array];
        for (NSDictionary *entry in message[@"chars"]) {
            SBCharacteristic *characteristic = [service sb_characteristicWithUUID:entry[@"uuid"]];
            if (characteristic == nil) {
                CBCharacteristicProperties properties = [entry[@"props"] unsignedIntegerValue];
                characteristic = [[SBCharacteristic alloc] initWithType:[CBUUID UUIDWithString:entry[@"uuid"]] properties:properties value:nil permissions:0];
                characteristic.sb_service = service;
                SBKeepAlive(characteristic);
            }
            [characteristics addObject:characteristic];
        }
        service.sb_characteristics = characteristics;
        if ([peripheralDelegate respondsToSelector:@selector(peripheral:didDiscoverCharacteristicsForService:error:)]) {
            [peripheralDelegate peripheral:peripheral didDiscoverCharacteristicsForService:service error:error];
        }
    } else if ([event isEqualToString:@"value"] || [event isEqualToString:@"wrote"] || [event isEqualToString:@"notifyState"]) {
        SBCharacteristic *characteristic = [[peripheral sb_serviceWithUUID:message[@"service"]] sb_characteristicWithUUID:message[@"char"]];
        if (characteristic == nil) {
            return;
        }
        if ([event isEqualToString:@"value"]) {
            if (error == nil) {
                characteristic.sb_value = SBData(message[@"data"]);
            }
            if ([peripheralDelegate respondsToSelector:@selector(peripheral:didUpdateValueForCharacteristic:error:)]) {
                [peripheralDelegate peripheral:peripheral didUpdateValueForCharacteristic:characteristic error:error];
            }
        } else if ([event isEqualToString:@"wrote"]) {
            if ([peripheralDelegate respondsToSelector:@selector(peripheral:didWriteValueForCharacteristic:error:)]) {
                [peripheralDelegate peripheral:peripheral didWriteValueForCharacteristic:characteristic error:error];
            }
        } else {
            characteristic.sb_notifying = [message[@"enabled"] boolValue];
            if ([peripheralDelegate respondsToSelector:@selector(peripheral:didUpdateNotificationStateForCharacteristic:error:)]) {
                [peripheralDelegate peripheral:peripheral didUpdateNotificationStateForCharacteristic:characteristic error:error];
            }
        }
    } else if ([event isEqualToString:@"rssi"]) {
        if ([peripheralDelegate respondsToSelector:@selector(peripheral:didReadRSSI:error:)]) {
            [peripheralDelegate peripheral:peripheral didReadRSSI:message[@"rssi"] ?: @0 error:error];
        }
    }
}

@end

#pragma mark - Installation

static IMP SBOriginalAllocWithZone;

static id SBAllocWithZone(Class self, SEL selector, struct _NSZone *zone) {
    Class target = self == [CBCentralManager class] ? [SBCentralManager class] : self;
    return ((id(*)(Class, SEL, struct _NSZone *))SBOriginalAllocWithZone)(target, selector, zone);
}

static CBManagerAuthorization SBAuthorization(Class self, SEL selector) {
    return CBManagerAuthorizationAllowedAlways;
}

__attribute__((constructor)) static void SBInstall(void) {
    // Adding +allocWithZone: to CBCentralManager's metaclass (instead of exchanging NSObject's)
    // limits the redirect to CBCentralManager; objc_alloc honours a class-specific allocWithZone:.
    Class metaclass = object_getClass([CBCentralManager class]);
    SEL allocSelector = @selector(allocWithZone:);
    SBOriginalAllocWithZone = method_getImplementation(class_getClassMethod([CBCentralManager class], allocSelector));
    if (!class_addMethod(metaclass, allocSelector, (IMP)SBAllocWithZone, "@@:^v")) {
        method_setImplementation(class_getClassMethod([CBCentralManager class], allocSelector), (IMP)SBAllocWithZone);
    }

    Method authorization = class_getClassMethod([CBManager class], @selector(authorization));
    if (authorization != NULL) {
        method_setImplementation(authorization, (IMP)SBAuthorization);
    }
    SBLog(@"installed in %@", NSBundle.mainBundle.bundleIdentifier ?: NSProcessInfo.processInfo.processName);
}
