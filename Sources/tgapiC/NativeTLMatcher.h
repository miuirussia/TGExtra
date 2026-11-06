#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "NativeTLProfile.inc"

enum { nativeBodyOffset = 524, nativeResultOffset = 1704, nativeParserSpan = 1816 };

static inline bool nativeCodeMatches(const uint32_t *code, const uint32_t pattern[][2], size_t count) {
    for (size_t i = 0; i < count; i++) if ((code[i] & pattern[i][1]) != pattern[i][0]) return false;
    return true;
}

static inline bool nativeParsersMatch(const uint8_t *text, size_t length, size_t offset) {
    if (length < nativeParserSpan || offset % 4 || offset > length - nativeParserSpan) return false;
    const uint8_t *candidate = text + offset;
    return nativeCodeMatches((const void *)candidate, native_constructor, sizeof(native_constructor)/sizeof(*native_constructor)) &&
        nativeCodeMatches((const void *)(candidate + nativeBodyOffset), native_body, sizeof(native_body)/sizeof(*native_body)) &&
        nativeCodeMatches((const void *)(candidate + nativeResultOffset), native_result, sizeof(native_result)/sizeof(*native_result));
}

static inline const uint8_t *nativeFindConstructor(const uint8_t *text, size_t length, bool hasOffset, size_t offset) {
    if (!text || length < nativeParserSpan) return NULL;
    if (hasOffset) return nativeParsersMatch(text, length, offset) ? text + offset : NULL;
    const uint8_t *constructor = NULL;
    for (size_t i = 0; i <= length - nativeParserSpan; i += 4) {
        const uint32_t *candidate = (const void *)(text + i);
        if (candidate[0] != native_constructor[0][0] || !nativeParsersMatch(text, length, i)) continue;
        if (constructor) return NULL;
        constructor = text + i;
    }
    return constructor;
}
