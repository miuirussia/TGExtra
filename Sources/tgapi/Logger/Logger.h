#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif
void customLog(NSString *format, ...);
void customLog2(NSString *format, ...);
NSString *TGExtraReadLog(void);
void TGExtraClearLog(void);
#ifdef __cplusplus
}
#endif

#define TGEXTRA_DIAG 0

#import <os/log.h>

#if TGEXTRA_DIAG
#define tgextraDiag(fmt, ...) os_log(OS_LOG_DEFAULT, "[TGExtraDiag] " fmt, ##__VA_ARGS__)
#else
#define tgextraDiag(fmt, ...) do { } while (0)
#endif
