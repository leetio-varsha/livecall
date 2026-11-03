#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs an input tap and returns AVFAudio's refusal as an error instead of
/// letting it kill the process. Returns nil when the tap went on.
///
/// `-installTapOnBus:bufferSize:format:block:` does not report failure by
/// returning something: when the format it is handed disagrees with what the
/// hardware currently is, it RAISES `com.apple.coreaudio.avfaudio` —
/// "Failed to create tap due to format mismatch". An ObjC exception is not a
/// Swift error: `do`/`catch` at the Swift call site never sees it, the runtime
/// reaches `std::terminate`, and Livecall dies with SIGABRT in the middle of a
/// call. It did, three times, always while a Bluetooth headset was switching
/// into headset mode and moving the mic from 48kHz to 16kHz.
///
/// The @try therefore lives here, in ObjC, with no Swift frame between it and
/// the call that raises — unwinding through Swift frames is undefined
/// behaviour, so the Swift side must stay outside the exception's path. The
/// tap block is only *stored* by this call; it runs later, on the render
/// thread, well outside the @try.
extern NSError *_Nullable LivecallInstallTap(AVAudioNode *node,
                                           AVAudioNodeBus bus,
                                           AVAudioFrameCount bufferSize,
                                           AVAudioFormat *_Nullable format,
                                           AVAudioNodeTapBlock block);

NS_ASSUME_NONNULL_END
