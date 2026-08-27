#ifndef CSYSTEMBRIDGE_H
#define CSYSTEMBRIDGE_H

/*
 * This header is the public face of the CSystemBridge C target. Swift code
 * elsewhere in the project imports CSystemBridge and calls these functions
 * directly, which is how Swift talks to libarchive and Mach kernel APIs in
 * later stages. Right now it only declares a placeholder function used to
 * prove the C target links correctly into the Swift build.
 */

/* Returns 1. Used only as a link and call smoke test for this target. */
int csystembridge_ping(void);

#endif
