//
//  SFNetSpeedMeasurer.m
//  NIM
//
//  Created by gzc on 2019/3/28.
//  Copyright © 2019 YzChina. All rights reserved.
//

#define MEASURER_ACCURACY_LEVEL_MIN (1)
#define MEASURER_ACCURACY_LEVEL_MAX (5)

#define WIFI_PREFIX  @"en"
#define WWAN_PREFIX  @"pdp_ip"

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>

#import "SFNetSpeedMeasurer.h"

@implementation SFNetFragmentation
+ (NSString *)maxValueInputKeyPath { return @"@max.inputBytesCount"; }
+ (NSString *)minValueInputKeyPath { return @"@min.inputBytesCount"; }
+ (NSString *)avgValueInputKeyPath { return @"@avg.inputBytesCount"; }
+ (NSString *)maxValueOutputKeyPath { return @"@max.outputBytesCount"; }
+ (NSString *)minValueOutputKeyPath { return @"@min.outputBytesCount"; }
+ (NSString *)avgValueOutputKeyPath { return @"@avg.outputBytesCount"; }
+ (NSString *)realTimeInputKeyPath { return  @"real.time.input"; }
+ (NSString *)realTimeOutputKeyPath { return  @"real.time.output"; }

- (NSString *)description {
    return [NSString stringWithFormat:@"connectionType : %lu, inputBytesCount : %u, outputBytesCount : %u, beginTimestamp : %f, endTimestamp : %f",(unsigned long)_connectionType, _inputBytesCount, _outputBytesCount, _beginTimestamp, _endTimestamp];
}
@end

@implementation SFNetMeasurerResult

- (NSString *)description {
    return [NSString stringWithFormat:@"\nUplink: \n{\n   max : %.2f MB/s, min : %.2f MB/s, avg : %.2f MB/s, cur : %.2f MB/s \n}, \nDownlink: \n{\n   max : %.2f MB/s, min : %.2f MB/s, avg : %.2f MB/s, cur : %.2f MB/s \n}\n",
            _uplinkMaxSpeed, _uplinkMinSpeed, _uplinkAvgSpeed, _uplinkCurSpeed, _downlinkMaxSpeed, _downlinkMinSpeed, _downlinkAvgSpeed, _downlinkCurSpeed];
}
@end

@interface SFNetSpeedMeasurer()
@property (nonatomic, strong) NSTimer *dispatchTimer;
@property (nonatomic, strong) NSMutableArray<SFNetFragmentation *> *fragmentArray;
@property (nonatomic) u_int32_t previousInputBytesCount;
@property (nonatomic) u_int32_t previousOutputBytesCount;
@end

@implementation SFNetSpeedMeasurer
@synthesize measurerBlock = _measurerBlock;
@synthesize measurerInterval = _measurerInterval;
@synthesize accuracyLevel = _accuracyLevel;
@synthesize delegate = _delegate;

- (void)dealloc {
#ifdef DEBUG
    NSLog(@"SFNetSpeedMeasurer Release");
#endif
}

#pragma mark -- Public Method ISpeedMeasurerProtocol

- (instancetype)initWithAccuracyLevel:(NSUInteger)accuracyLevel interval:(NSTimeInterval)interval {
    self = [super init];
    if (self) {
        self.accuracyLevel = accuracyLevel;
        self.measurerInterval = interval;
    }
    return self;
}

- (void)setMeasurerInterval:(NSTimeInterval)measurerInterval {
    _measurerInterval = measurerInterval <= 0.f ? 1.f : measurerInterval;
}

- (void)setAccuracyLevel:(NSUInteger)accuracyLevel {
    NSUInteger max = MEASURER_ACCURACY_LEVEL_MAX;
    NSUInteger min = MEASURER_ACCURACY_LEVEL_MIN;
    _accuracyLevel = accuracyLevel >= min ? accuracyLevel <= max ?: max : min;
}

- (void)initPreviousValue {
    SFNetFragmentation *fragment = [self currentNetCardTrafficData];
    if(!fragment) return;
    _previousInputBytesCount = fragment.inputBytesCount;
    _previousOutputBytesCount = fragment.outputBytesCount;
}

- (void)execute {
    if (_dispatchTimer) return;
    [self initPreviousValue];
    _dispatchTimer = [NSTimer scheduledTimerWithTimeInterval:self.measurerInterval target:self selector:@selector(dispatch) userInfo:nil repeats:YES];
    NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
    [runLoop addTimer:_dispatchTimer forMode:NSRunLoopCommonModes];
}

- (void)shutdown {
    if (!_dispatchTimer) return;
    [_dispatchTimer invalidate];
    _dispatchTimer = nil;
    //
    _previousInputBytesCount = 0;
    _previousOutputBytesCount = 0;
    //
    [_fragmentArray removeAllObjects];
}

- (SFNetFragmentation * _Nullable )currentNetCardTrafficData {
    struct ifaddrs *ifa_list = 0, *ifa;
    if (getifaddrs(&ifa_list) == -1) {
        return nil;
    }
    
    u_int32_t ibytes = 0;
    u_int32_t obytes = 0;
    //统计网卡上下行流量
    for (ifa = ifa_list; ifa; ifa = ifa->ifa_next) {
        if (AF_LINK != ifa->ifa_addr->sa_family) continue;
        if (!(ifa->ifa_flags & IFF_UP) && !(ifa->ifa_flags & IFF_RUNNING))  continue;
        if (ifa->ifa_data == 0) continue;
        
        /* Not a loopback device. */
        if (strncmp(ifa->ifa_name, "lo", 2)) {
            struct if_data *if_data = (struct if_data *)ifa->ifa_data;
            ibytes += if_data->ifi_ibytes;
            obytes += if_data->ifi_obytes;
        }
    }
    //
    NSString* ifa_name = [NSString stringWithCString:ifa_list->ifa_name encoding:NSUTF8StringEncoding];
    SFNetConnectionType type = SFNetConnectionType_WWAN;
    if ([ifa_name hasPrefix:WIFI_PREFIX]) {
        type = SFNetConnectionType_WiFi;
    }
    SFNetFragmentation *fragment = [self wrapFragmentWithConntype:type inputBytes:ibytes outputBytes:obytes];
    //
    freeifaddrs(ifa_list);
    return fragment;
}

- (SFNetFragmentation *)wrapFragmentWithConntype:(SFNetConnectionType)type inputBytes:(u_int32_t)ibytes outputBytes:(u_int32_t)obytes {
    SFNetFragmentation *fragment = [[SFNetFragmentation alloc] init];
    fragment.endTimestamp = [[NSDate date] timeIntervalSince1970];
    fragment.beginTimestamp = fragment.endTimestamp - self.measurerInterval;
    fragment.inputBytesCount = ibytes - _previousInputBytesCount;
    fragment.outputBytesCount = obytes - _previousOutputBytesCount;
    fragment.connectionType = type;
    //
    _previousInputBytesCount = ibytes;
    _previousOutputBytesCount = obytes;
    //
    return fragment;
}

- (void)dispatch {
    SFNetFragmentation *fragment = [self currentNetCardTrafficData];
    if(!fragment) return;
    if (_fragmentArray.count >= self.maxFramentArrayCapacity) {
        [_fragmentArray removeObjectAtIndex:0];
    }
    [self.fragmentArray addObject:fragment];
    [self calculateSpeed];
}

- (void)calculateSpeed {
    SFNetMeasurerResult *result = [[SFNetMeasurerResult alloc] init];
    result.connectionType = self.fragmentArray.lastObject.connectionType;
    {//上行
        result.uplinkMaxSpeed = [self calculateSpeedWithKeyPath:SFNetFragmentation.maxValueOutputKeyPath];
        result.uplinkMinSpeed = [self calculateSpeedWithKeyPath:SFNetFragmentation.minValueOutputKeyPath];
        result.uplinkAvgSpeed = [self calculateSpeedWithKeyPath:SFNetFragmentation.avgValueOutputKeyPath];
        result.uplinkCurSpeed = [self calculateRealTimeSpeedWithKeyPath:SFNetFragmentation.realTimeOutputKeyPath];
    }
    {//下行
        result.downlinkMaxSpeed = [self calculateSpeedWithKeyPath:SFNetFragmentation.maxValueInputKeyPath];
        result.downlinkMinSpeed = [self calculateSpeedWithKeyPath:SFNetFragmentation.minValueInputKeyPath];
        result.downlinkAvgSpeed = [self calculateSpeedWithKeyPath:SFNetFragmentation.avgValueInputKeyPath];
        result.downlinkCurSpeed = [self calculateRealTimeSpeedWithKeyPath:SFNetFragmentation.realTimeInputKeyPath];
    }
    
    if (_measurerBlock) {
        _measurerBlock(result);
        return;
    }
    
    if (_delegate && [_delegate respondsToSelector:@selector(measurer:didCompletedByInterval:)]) {
        [_delegate measurer:self didCompletedByInterval:result];
    }
}

- (double)calculateSpeedWithKeyPath:(NSString *)keyPath {
    double bytesInMegabyte = 1024 * 1024;
    double maxPerMeasureInterval = [[self.fragmentArray valueForKeyPath:keyPath] doubleValue] / bytesInMegabyte;
    return maxPerMeasureInterval / self.measurerInterval;
}

- (double)calculateRealTimeSpeedWithKeyPath:(NSString *)keyPath {
    if (NSDate.date.timeIntervalSinceNow - _fragmentArray.lastObject.endTimestamp > self.measurerInterval) {
        return 0;
    }
    uint32_t bytesCount = _fragmentArray.lastObject.inputBytesCount;
    if ([keyPath isEqualToString:SFNetFragmentation.realTimeOutputKeyPath]) {
        bytesCount = _fragmentArray.lastObject.outputBytesCount;
    }
    double bytesPerSecondInBytes = bytesCount / self.measurerInterval;
    double bytesInMegabyte = 1024 * 1024;
    return bytesPerSecondInBytes / bytesInMegabyte;
}

- (NSMutableArray<SFNetFragmentation *> *)fragmentArray {
    if (_fragmentArray) return _fragmentArray;
    int capacity = [self maxFramentArrayCapacity];
    _fragmentArray = [[NSMutableArray alloc] initWithCapacity:capacity];
    return _fragmentArray;
}

- (int)maxFramentArrayCapacity {
    return (1 / _measurerInterval) * _accuracyLevel * 600;
}

@end
