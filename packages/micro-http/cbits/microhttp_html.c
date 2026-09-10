#include <string.h>

#include "microhttp_html.h"

/* The entity for a special byte, or NULL for a byte that passes through. */
static const char *entity_for(unsigned char c) {
    switch (c) {
    case '<':
        return "&lt;";
    case '>':
        return "&gt;";
    case '&':
        return "&amp;";
    case '"':
        return "&quot;";
    case '\'':
        return "&#39;";
    default:
        return NULL;
    }
}

long mhhtml_escaped_length(const unsigned char *in, long len) {
    long out = 0;
    for (long i = 0; i < len; i++) {
        const char *entity = entity_for(in[i]);
        out += entity ? (long) strlen(entity) : 1;
    }
    return out;
}

long mhhtml_escape(const unsigned char *in, long len, unsigned char *out) {
    long written = 0;
    for (long i = 0; i < len; i++) {
        const char *entity = entity_for(in[i]);
        if (entity) {
            size_t n = strlen(entity);
            memcpy(out + written, entity, n);
            written += (long) n;
        } else {
            out[written++] = in[i];
        }
    }
    return written;
}
