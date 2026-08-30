#ifndef CSYSTEMBRIDGE_H
#define CSYSTEMBRIDGE_H

/*
 * This header is the public face of the CSystemBridge C target. Swift code
 * elsewhere in the project imports CSystemBridge and calls these functions
 * directly. This target holds our own hand-written C glue code (Mach
 * kernel telemetry bindings arrive here in Stage 4). libarchive is a
 * separate concern, wrapped by the CArchive systemLibrary target instead:
 * code that needs libarchive imports CArchive directly rather than going
 * through here, since libarchive's own headers are already directly
 * callable from Swift with no wrapper needed at all.
 */

/* Returns 1. Used only as a link and call smoke test for this target. */
int csystembridge_ping(void);

#endif
