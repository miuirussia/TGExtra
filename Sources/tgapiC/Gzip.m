#import "include/Tweak.h"
#include <zlib.h>
#include <limits.h>

NSData *decompressGzip(const void *input, size_t inputLen) {
    if (!input || inputLen < 2 || inputLen > UINT_MAX) return nil;
    z_stream stream = {0};
    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)inputLen;
    if (inflateInit2(&stream, 47) != Z_OK) return nil;
    NSMutableData *result = [NSMutableData data];
    uint8_t chunk[65536];
    int status;
    do {
        stream.next_out = chunk;
        stream.avail_out = sizeof(chunk);
        status = inflate(&stream, Z_NO_FLUSH);
        if (status != Z_OK && status != Z_STREAM_END) break;
        NSUInteger produced = sizeof(chunk) - stream.avail_out;
        if (result.length + produced > 64 * 1024 * 1024) {
            status = Z_MEM_ERROR;
            break;
        }
        [result appendBytes:chunk length:produced];
    } while (status != Z_STREAM_END);
    inflateEnd(&stream);
    return status == Z_STREAM_END ? result : nil;
}
