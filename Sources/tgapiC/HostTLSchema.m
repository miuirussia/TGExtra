#import "include/Tweak.h"
#import <dlfcn.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>
#include <zlib.h>
#include <limits.h>

// The host's TLS1 table contains wire field order, optional flags and type
// references. Read its original compressed image without calling hidden APIs.
static NSData *schemaInBytes(const uint8_t *bytes, size_t length) {
    if (length < 72 || length > UINT_MAX) return nil;
    NSData *found;
    for (size_t offset = 0; offset + 72 <= length; offset++) {
        if (bytes[offset] != 0x78 || (bytes[offset + 1] != 0x01 && bytes[offset + 1] != 0x5e &&
            bytes[offset + 1] != 0x9c && bytes[offset + 1] != 0xda)) continue;
        uint32_t header[18] = {0};
        z_stream stream = {0};
        stream.next_in = (Bytef *)bytes + offset;
        stream.avail_in = (uInt)(length - offset);
        stream.next_out = (Bytef *)header;
        stream.avail_out = sizeof(header);
        if (inflateInit(&stream) != Z_OK) return nil;
        int status = inflate(&stream, Z_NO_FLUSH);
        BOOL candidate = (status == Z_OK || status == Z_STREAM_END) && stream.avail_out == 0 &&
            header[0] == 0x31534c54 && header[1] == 3 && header[4] >= 72 && header[4] <= 16 * 1024 * 1024;
        inflateEnd(&stream);
        if (!candidate) continue;
        NSData *image = decompressGzip(bytes + offset, length - offset);
        if (image.length != header[4]) continue;
        if (found) return nil; // Never choose between conflicting protocol tables.
        found = image;
    }
    return found;
}

NSData *TGExtraHostTLSchema(void) {
    static NSData *schema;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
#ifdef TGEXTRA_TESTING
        const char *fixturePath = getenv("TGEXTRA_TL_SCHEMA");
        if (fixturePath) {
            NSData *fixture = [NSData dataWithContentsOfFile:@(fixturePath)];
            schema = schemaInBytes(fixture.bytes, fixture.length);
            return;
        }
#endif
        Class root = objc_lookUpClass("TLObject");
        Dl_info image;
        if (!root || !dladdr((__bridge const void *)root, &image) || !image.dli_fbase) return;
        const struct mach_header_64 *header = image.dli_fbase;
        if (header->magic != MH_MAGIC_64 || header->sizeofcmds > 1024 * 1024) return;
        const uint8_t *command = (const void *)(header + 1);
        const uint8_t *end = command + header->sizeofcmds;
        const struct segment_command_64 *text = NULL;
        for (uint32_t i = 0; i < header->ncmds; i++) {
            if ((size_t)(end - command) < sizeof(struct load_command)) return;
            const struct load_command *load = (const void *)command;
            if (load->cmdsize < sizeof(*load) || load->cmdsize > (size_t)(end - command)) return;
            if (load->cmd == LC_SEGMENT_64 && load->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *segment = (const void *)load;
                if (!strncmp(segment->segname, "__TEXT", 16) && segment->fileoff == 0) text = segment;
            }
            command += load->cmdsize;
        }
        if (!text || text->filesize < 72 || text->filesize > 256 * 1024 * 1024) return;
        // __TEXT is read-only and fully file-backed in the supported arm64 apps.
        schema = schemaInBytes(image.dli_fbase, (size_t)text->filesize);
    });
    return schema;
}
