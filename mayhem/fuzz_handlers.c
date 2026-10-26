// Fuzz every public libdemangle language handler (rz_libdemangle.h). The first byte picks the
// handler and the option set; the rest is the symbol. Complements fuzz/fuzz_demangle.c, which
// drives only the Itanium v3 parser directly.
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "rz_libdemangle.h"

typedef char *(*handler_t)(const char *symbol, RzDemangleOpts opts);

static const handler_t handlers[] = {
	libdemangle_handler_cxx,
	libdemangle_handler_rust,
#if WITH_SWIFT_DEMANGLER
	libdemangle_handler_swift,
#endif
	libdemangle_handler_java,
	libdemangle_handler_msvc,
	libdemangle_handler_objc,
	libdemangle_handler_pascal,
	libdemangle_handler_d,
};

#define N_HANDLERS (sizeof(handlers) / sizeof(handlers[0]))

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
	if (size < 2 || size > 4096) {
		return -1;
	}
	handler_t handler = handlers[(data[0] >> 1) % N_HANDLERS];
	RzDemangleOpts opts = (data[0] & 1) ? RZ_DEMANGLE_OPT_SIMPLIFY : RZ_DEMANGLE_OPT_BASE;

	size_t len = size - 1;
	char *buf = malloc(len + 1);
	if (!buf) {
		return 0;
	}
	memcpy(buf, data + 1, len);
	buf[len] = '\0';

	char *result = handler(buf, opts);
	free(buf);
	if (!result) {
		return -1;
	}
	free(result);
	return 0;
}
