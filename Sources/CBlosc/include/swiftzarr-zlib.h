#ifndef SWIFTZARR_ZLIB_H
#define SWIFTZARR_ZLIB_H

// NIO's bundled zlib also declares this unprefixed gzip file structure.
// Give our imported structure a unique tag so Clang does not merge the two
// definitions. This does not change zlib function symbols or structure layout.
#define gzFile_s swiftzarr_gzFile_s
#include "../deps/c-blosc/internal-complibs/zlib-1.3.1/zlib.h"
#undef gzFile_s

#endif
