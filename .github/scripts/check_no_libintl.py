#!/usr/bin/env python3
"""Fail when Mach-O files or static archives carry GNU libintl object code.

cmux builds GhosttyKit and the ghostty CLI helper with -Di18n=false and must
not ship GNU libintl (LGPL-2.1-or-later). This parses Mach-O, universal (fat)
and ar files directly instead of using `nm`, because an older Xcode `nm` on CI
silently fails to read Zig-built archives. Any file or member it cannot parse
is an error, so the check cannot pass by reading nothing.

Usage: check_no_libintl.py <path>...
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

MH_MAGIC, MH_MAGIC_64 = 0xFEEDFACE, 0xFEEDFACF
FAT_MAGIC, FAT_MAGIC_64 = 0xCAFEBABE, 0xCAFEBABF
AR_MAGIC = b"!<arch>\n"
LIBINTL_MEMBERS = {"dcigettext.o", "loadmsgcat.o", "bindtextdom.o"}


class Unreadable(Exception):
    pass


def macho_defined(data: bytes) -> list[str]:
    magic = struct.unpack_from("<I", data, 0)[0] if len(data) >= 4 else 0
    if magic == MH_MAGIC_64:
        header, nlist = 32, 16
    elif magic == MH_MAGIC:
        header, nlist = 28, 12
    else:
        raise Unreadable(f"not a Mach-O object (magic {magic:#x})")
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off, names = header, []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x2:  # LC_SYMTAB
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", data, off + 8)
            for i in range(nsyms):
                strx, ntype = struct.unpack_from("<IB", data, symoff + i * nlist)
                if ntype & 0xE0 or (ntype & 0x0E) == 0:
                    continue
                start = stroff + strx
                end = data.find(b"\0", start, stroff + strsize)
                names.append(data[start:end].decode("utf-8", "replace"))
        if size < 8:
            raise Unreadable("bad load command size")
        off += size
    return names


def ar_members(data: bytes):
    off = len(AR_MAGIC)
    while off + 60 <= len(data):
        h = data[off : off + 60]
        name = h[:16].decode("ascii", "replace").strip()
        size = int(h[48:58].decode("ascii").strip())
        body = data[off + 60 : off + 60 + size]
        if name.startswith("#1/"):
            n = int(name[3:])
            name, body = body[:n].rstrip(b"\0").decode("utf-8", "replace"), body[n:]
        yield name.rstrip("/"), body
        off += 60 + size + (size & 1)


def scan(data: bytes, label: str) -> tuple[list[str], int]:
    """Return (hits, objects_read)."""
    if data.startswith(AR_MAGIC):
        hits, read = [], 0
        for name, body in ar_members(data):
            if name.startswith("__.SYMDEF") or name in ("", "/", "//"):
                continue
            if name in LIBINTL_MEMBERS:
                hits.append(f"{label}({name}): libintl archive member")
            h, r = scan(body, f"{label}({name})")
            hits += h
            read += r
        return hits, read
    magic_be = struct.unpack_from(">I", data, 0)[0] if len(data) >= 4 else 0
    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        nfat = struct.unpack_from(">I", data, 4)[0]
        size = 32 if magic_be == FAT_MAGIC_64 else 20
        hits, read = [], 0
        for i in range(nfat):
            fields = struct.unpack_from(">iiQQ" if size == 32 else ">iiII", data, 8 + i * size)
            h, r = scan(data[fields[2] : fields[2] + fields[3]], f"{label}[cpu {fields[0]:#x}]")
            hits += h
            read += r
        return hits, read
    return [f"{label}: {s}" for s in macho_defined(data) if s.startswith(("_libintl_", "__libintl_"))], 1


def is_candidate(path: Path) -> bool:
    head = path.read_bytes()[:8]
    if head.startswith(AR_MAGIC):
        return True
    return len(head) >= 4 and (
        struct.unpack_from("<I", head, 0)[0] in (MH_MAGIC, MH_MAGIC_64)
        or struct.unpack_from(">I", head, 0)[0] in (FAT_MAGIC, FAT_MAGIC_64)
    )


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    files, failed, objects = 0, False, 0
    for root in map(Path, argv):
        if not root.exists():
            print(f"error: {root} does not exist", file=sys.stderr)
            return 1
        for path in sorted([root] if root.is_file() else (p for p in root.rglob("*") if p.is_file() and not p.is_symlink())):
            if not is_candidate(path):
                continue
            files += 1
            try:
                hits, read = scan(path.read_bytes(), str(path))
            except (Unreadable, struct.error, ValueError) as error:
                print(f"::error file={path}::cannot parse: {error}")
                failed = True
                continue
            objects += read
            print(f"checked {path}: {read} Mach-O objects, {len(hits)} libintl hits")
            if hits:
                failed = True
                print(f"::error file={path}::libintl object code found")
                for hit in hits[:10]:
                    print(f"  {hit}")
    print(f"checked {files} files, {objects} Mach-O objects")
    if files == 0 or objects == 0:
        print("error: nothing was checked", file=sys.stderr)
        return 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
