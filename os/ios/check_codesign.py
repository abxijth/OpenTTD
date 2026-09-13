#!/usr/bin/env python3
"""Verify that a Mach-O binary actually carries an embedded code signature.

Fails (exit code 1) when the binary:
  * has no LC_CODE_SIGNATURE load command,
  * references a zero/empty signature blob (datasize <= 8),
  * the blob's magic is not CSMAGIC_EMBEDDED_SIGNATURE (0xfade0cc0),
  * or the blob is out of bounds / otherwise malformed.

This guards CI against the failure mode where an unsigned binary slips
through packaging: a Mach-O produced by the Apple toolchain always carries
an (empty) LC_CODE_SIGNATURE, so a naive "is there a load command" check is
not enough -- we must confirm the blob is genuinely populated.
"""

import struct
import sys

LC_CODE_SIGNATURE = 0x1d
CSMAGIC_EMBEDDED_SIGNATURE = 0xfade0cc0

# Thin Mach-O 64/32 bit header offsets (little-endian).
MAGIC_64 = 0xfeedfacf
MAGIC_32 = 0xfeedface


def fail(message):
    print(f"::error::Signature check failed: {message}", file=sys.stderr)
    sys.exit(1)


def check(path):
    with open(path, "rb") as f:
        data = f.read()

    if len(data) < 28:
        fail("file too small to be a Mach-O")

    magic = struct.unpack_from("<I", data, 0)[0]
    if magic not in (MAGIC_64, MAGIC_32):
        fail(f"not a thin Mach-O image (header magic=0x{magic:08x})")

    is64 = magic == MAGIC_64
    header_size = 32 if is64 else 28
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)

    if header_size + sizeofcmds > len(data):
        fail("load commands extend past end of file")

    off = header_size
    found = False
    for _ in range(ncmds):
        if off + 8 > len(data):
            fail("truncated load command table")
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmdsize < 8 or off + cmdsize > len(data):
            fail(f"malformed load command (cmd={cmd:#x} cmdsize={cmdsize})")
        if cmd == LC_CODE_SIGNATURE:
            found = True
            dataoff, datasize = struct.unpack_from("<II", data, off + 8)
            print(f"LC_CODE_SIGNATURE: dataoff={dataoff} datasize={datasize}")
            if datasize <= 8:
                fail(f"signature blob is empty (datasize={datasize})")
            if dataoff + datasize > len(data):
                fail("signature blob extends past end of file")
            # The embedded Code Signature blob is big-endian, even though the
            # Mach-O load command that points to it is little-endian.
            blob_magic, blob_len = struct.unpack_from(">II", data, dataoff)
            if blob_magic != CSMAGIC_EMBEDDED_SIGNATURE:
                fail(
                    f"bad signature blob magic 0x{blob_magic:08x} "
                    f"(expected 0x{CSMAGIC_EMBEDDED_SIGNATURE:08x})"
                )
            if blob_len < 16:
                fail(f"signature blob length {blob_len} is too small")
            print(
                f"Signature blob OK (magic=0x{blob_magic:08x}, length={blob_len}, "
                f"codesign magic embedded)"
            )
            break
        off += cmdsize

    if not found:
        fail("no LC_CODE_SIGNATURE load command found")

    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        fail("usage: check_codesign.py <mach-o binary>")
    sys.exit(check(sys.argv[1]))