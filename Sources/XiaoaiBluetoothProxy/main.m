#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <unistd.h>
#import <signal.h>
#import <errno.h>

@interface Proxy : NSObject <IOBluetoothRFCOMMChannelDelegate>
@property(nonatomic, strong) IOBluetoothRFCOMMChannel *channel;
@property(nonatomic, strong) dispatch_semaphore_t serverReady;
@property(nonatomic) BOOL receivedServerData;
@end
@implementation Proxy
- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)channel data:(void *)bytes length:(size_t)length {
    if (!self.receivedServerData) {
        self.receivedServerData = YES;
        alarm(0);
        dispatch_semaphore_signal(self.serverReady);
    }
    size_t offset = 0;
    while (offset < length) {
        ssize_t n = write(STDOUT_FILENO, (char *)bytes + offset, length - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) exit(1);
        offset += n;
    }
}
- (void)rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)channel { exit(0); }
@end
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "Usage: XiaoaiBluetoothProxy XX:XX:XX:XX:XX:XX\n"); return 64; }
        NSString *address = [NSString stringWithUTF8String:argv[1]];
        NSPredicate *valid = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", @"[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}"];
        if (![valid evaluateWithObject:address]) return 64;
        // Bound connection setup through the first server bytes; established sessions may stay open.
        alarm(25);
        signal(SIGPIPE, SIG_IGN);
        Proxy *proxy = [Proxy new];
        proxy.serverReady = dispatch_semaphore_create(0);
        IOBluetoothDevice *device = [IOBluetoothDevice deviceWithAddressString:address];
        IOBluetoothRFCOMMChannel *channel = nil;
        IOReturn result = [device openRFCOMMChannelSync:&channel withChannelID:23 delegate:proxy];
        if (result || !channel) { fprintf(stderr, "RFCOMM open failed: 0x%x\n", result); return 1; }
        proxy.channel = channel;
        fprintf(stderr, "RFCOMM connected, MTU=%u\n", channel.getMTU);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            // BlueZ flushes its TTY while accepting RFCOMM. Wait for Dropbear
            // to send its banner before forwarding any client handshake bytes.
            dispatch_semaphore_wait(proxy.serverReady, DISPATCH_TIME_FOREVER);
            unsigned char bytes[4096];
            for (;;) {
                ssize_t length = read(STDIN_FILENO, bytes, sizeof(bytes));
                if (length < 0 && errno == EINTR) continue;
                if (length <= 0) exit(length == 0 ? 0 : 1);
                unsigned char *chunk = bytes;
                // Wait for each bounded chunk before reading more from SSH.
                dispatch_sync(dispatch_get_main_queue(), ^{
                    NSUInteger offset = 0;
                    UInt16 mtu = channel.getMTU;
                    if (!mtu) exit(1);
                    while (offset < length) {
                        UInt16 count = MIN(mtu, length - offset);
                        if ([channel writeSync:chunk + offset length:count]) exit(1);
                        offset += count;
                    }
                });
            }
        });
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
