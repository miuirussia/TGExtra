#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif
void customLog(NSString *format, ...);
void customLog2(NSString *format, ...);
#ifdef __cplusplus
}
#endif

// Diagnostic logging for on-device testing.
//
// Deliberately NSLog rather than customLog2: customLog2 only writes to a file
// inside the app sandbox, which is unreachable from `idevicesyslog` on a
// tethered Mac. Set TGEXTRA_DIAG to 0 to compile these out for a release build.
// Set to 1 for on-device debugging. Keep TLParser.diagEnabled in step — that
// one gates the Swift half, which this macro cannot reach.
#define TGEXTRA_DIAG 0

// os_log rather than NSLog, and the format is a C string rather than an
// NSString: strings logged without a {public} annotation reach the syslog as the
// literal text "<private>", and clang only accepts that annotation inside
// os_log(). Scalars are public by default, so only %@ and %s need marking.
//
//     tgextraDiag("thing cls=%{public}@ id=%lld", cls, peerId);
#import <os/log.h>

#if TGEXTRA_DIAG
#define tgextraDiag(fmt, ...) os_log(OS_LOG_DEFAULT, "[TGExtraDiag] " fmt, ##__VA_ARGS__)
#else
#define tgextraDiag(fmt, ...) do { } while (0)
#endif
