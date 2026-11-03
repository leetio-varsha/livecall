#import "TapInstall.h"

NSError *_Nullable LivecallInstallTap(AVAudioNode *node,
                                    AVAudioNodeBus bus,
                                    AVAudioFrameCount bufferSize,
                                    AVAudioFormat *_Nullable format,
                                    AVAudioNodeTapBlock block) {
    @try {
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return nil;
    } @catch (NSException *raised) {
        // The reason carries the two formats that disagreed, which is the only
        // way to tell a device that moved from a device that is simply gone.
        NSString *why = raised.reason ?: @"no reason given";
        return [NSError errorWithDomain:@"livecall.mic"
                                   code:3
                               userInfo:@{
                                   NSLocalizedDescriptionKey:
                                       [NSString stringWithFormat:@"installTap raised %@: %@",
                                                                  raised.name, why],
                               }];
    }
}
