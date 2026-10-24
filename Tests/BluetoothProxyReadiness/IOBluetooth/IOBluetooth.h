#import <Foundation/Foundation.h>
typedef int IOReturn;
@class IOBluetoothRFCOMMChannel;
@protocol IOBluetoothRFCOMMChannelDelegate <NSObject>
- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)channel data:(void *)data length:(size_t)length;
- (void)rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)channel;
@end
@interface IOBluetoothRFCOMMChannel : NSObject
- (UInt16)getMTU;
- (IOReturn)writeSync:(void *)data length:(UInt16)length;
@end
@interface IOBluetoothDevice : NSObject
+ (instancetype)deviceWithAddressString:(NSString *)address;
- (IOReturn)openRFCOMMChannelSync:(IOBluetoothRFCOMMChannel **)channel withChannelID:(int)channelID delegate:(id<IOBluetoothRFCOMMChannelDelegate>)delegate;
@end
