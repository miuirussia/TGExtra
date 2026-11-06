#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "../Sources/tgapiC/NativeTLMatcher.h"

static void fillPattern(uint8_t *target, const uint32_t pattern[][2], size_t count) {
    for (size_t i = 0; i < count; i++) memcpy(target + i*4, &pattern[i][0], 4);
}

int main(int argc, char **argv) {
    uint8_t text[nativeParserSpan*2 + 4] = {0};
    const size_t offset = 4;
    fillPattern(text + offset, native_constructor, sizeof(native_constructor)/sizeof(*native_constructor));
    fillPattern(text + offset + nativeBodyOffset, native_body, sizeof(native_body)/sizeof(*native_body));
    fillPattern(text + offset + nativeResultOffset, native_result, sizeof(native_result)/sizeof(*native_result));
    assert(nativeFindConstructor(text, sizeof(text), false, 0) == text + offset);
    assert(nativeFindConstructor(text, sizeof(text), true, offset) == text + offset);
    assert(!nativeFindConstructor(text, sizeof(text), true, 0));
    assert(!nativeFindConstructor(text, sizeof(text), true, offset + 1));
    assert(!nativeFindConstructor(text, sizeof(text), true, SIZE_MAX));
    assert(!nativeFindConstructor(text, offset + nativeParserSpan - 1, true, offset));
    assert(!nativeFindConstructor(NULL, sizeof(text), true, offset));
    text[offset + nativeBodyOffset] ^= 1;
    assert(!nativeFindConstructor(text, sizeof(text), true, offset));
    text[offset + nativeBodyOffset] ^= 1;
    memcpy(text + offset + nativeParserSpan, text + offset, nativeParserSpan);
    assert(!nativeFindConstructor(text, sizeof(text), false, 0));
    assert(nativeFindConstructor(text, sizeof(text), true, offset) == text + offset);

    // Valid metadata must not read any unrelated part of __text.
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    assert(page >= nativeParserSpan);
    uint8_t *guarded = mmap(NULL, page*2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(guarded != MAP_FAILED);
    memcpy(guarded, text + offset, nativeParserSpan);
    assert(mprotect(guarded + page, page, PROT_NONE) == 0);
    assert(nativeFindConstructor(guarded, page*2, true, 0) == guarded);
    assert(munmap(guarded, page*2) == 0);

    if (argc == 3) {
        FILE *file = fopen(argv[1], "rb");
        assert(file);
        assert(fseek(file, 0, SEEK_END) == 0);
        long size = ftell(file);
        assert(size >= 0);
        rewind(file);
        uint8_t *bytes = malloc((size_t)size);
        assert(bytes && fread(bytes, 1, (size_t)size, file) == (size_t)size);
        assert(fclose(file) == 0);
        size_t at = (size_t)strtoull(argv[2], NULL, 10);
        assert(nativeFindConstructor(bytes, (size_t)size, false, 0) == bytes + at);
        assert(nativeFindConstructor(bytes, (size_t)size, true, at) == bytes + at);
        free(bytes);
    }
    puts("PASS native matcher: direct metadata path, guarded reads, bounds, code masks and unique fallback");
}
