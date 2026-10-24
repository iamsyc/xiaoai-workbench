#import <IOBluetooth/IOBluetooth.h>
#include <stdlib.h>
static id<IOBluetoothRFCOMMChannelDelegate> receiver;
static BOOL ready;
static NSMutableData *received;
@implementation IOBluetoothRFCOMMChannel
- (UInt16)getMTU { return 4; }
- (IOReturn)writeSync:(void *)data length:(UInt16)length {
    // Models the BlueZ TTY flush before its SSH bridge starts.
    if (!ready) { fprintf(stderr, "CLIENT_BYTES_BEFORE_SERVER_READY\n"); exit(42); }
    if (length > 4) exit(43);
    [received appendBytes:data length:length];
    if (received.length == 16) {
        NSData *expected = [@"client-handshake" dataUsingEncoding:NSUTF8StringEncoding];
        if (![received isEqualToData:expected]) exit(44);
        [receiver rfcommChannelData:self data:received.mutableBytes length:received.length];
        exit(0);
    }
    return 0;
}
@end
@implementation IOBluetoothDevice
+ (instancetype)deviceWithAddressString:(NSString *)address { return [self new]; }
- (IOReturn)openRFCOMMChannelSync:(IOBluetoothRFCOMMChannel **)channel withChannelID:(int)channelID delegate:(id<IOBluetoothRFCOMMChannelDelegate>)delegate {
    if (channelID != 23) exit(45);
    receiver = delegate; received = [NSMutableData data];
    IOBluetoothRFCOMMChannel *transport = [IOBluetoothRFCOMMChannel new];
    *channel = transport;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        ready = YES;
        char banner[] = "SSH-2.0-fixture\r\n";
        [receiver rfcommChannelData:transport data:banner length:sizeof(banner) - 1];
    });
    return 0;
}
@end
