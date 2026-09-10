/* HTML escaping for MicroHttp.Html (RFC-0039): escapes the five
 * HTML-significant bytes (< > & " ') into their entities and passes every
 * other byte through, so UTF-8 content is escaped correctly at the byte level
 * (no multibyte sequence contains an ASCII byte). Done in C because a
 * document embedded in a page used to be unpacked to a Haskell list to be
 * escaped -- ~190x its size in heap cells, transiently, per request -- and a
 * memchr-per-special scan still pays a foreign call per special.
 */
#ifndef MICROHTTP_HTML_H
#define MICROHTTP_HTML_H

/* The byte length of the escaped form of in[0..len). */
long mhhtml_escaped_length(const unsigned char *in, long len);

/* Writes the escaped form of in[0..len) to out, which must hold
 * mhhtml_escaped_length(in, len) bytes. Returns the bytes written. */
long mhhtml_escape(const unsigned char *in, long len, unsigned char *out);

#endif
