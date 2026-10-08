#!/usr/bin/env python3
"""
initrd-audit -- check the boot payload against the kernel that will run it.

Companion to dt-audit.py. That one checks the device tree against the drivers;
this one checks the initramfs and the kernel config against each other, which
is the axis that started costing reboots once the device tree was clean.

  FW-COMPRESS  firmware shipped compressed that the kernel cannot decompress.
               The INTEG initramfs carries 29 .zst firmware files including
               qcom/x1e80100/gen70500_zap.mbn.zst, and CONFIG_FW_LOADER_COMPRESS
               is not set -- so request_firmware() returns -ENOENT for all of
               them even though the bytes are right there. Provable offline;
               it cost several boots to notice as three unexplained -2s.

  MOD-COMPRESS the same trap for modules.

  HOOK-TOOLS   a dracut hook calling a command the initramfs does not contain.
               Our pre-pivot hook used `du`, `head`, `cut` and `basename`, none
               of which exist there. The size guard failed open, so it reported
               success and copied nothing, and the failure looked like "there
               was no journal" rather than "the check is broken."

  HOOK-EXIT    dracut SOURCES hook files, so a live `exit` aborts
               dracut-pre-pivot before its own `source_hook cleanup`.

  CONFIG-REQ   symbols we have learned the hard way this machine needs, each
               with the observed consequence of it being off. A regression
               guard: once a boot teaches us something, a later rebuild should
               not be able to silently lose it.

Usage:
  initrd-audit.py --initrd /mnt/c/sp11-stage/initrd-sp11log.img \
                  --config /root/sp11/wt-ov13858/.config
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict

# Symbols this machine has been observed to need, and what breaks without them.
CONFIG_REQ = [
    ("CONFIG_FW_LOADER_COMPRESS", "y",
     "the initramfs and rootfs ship zstd-compressed firmware; without this "
     "every one of them returns -ENOENT with the bytes present on disk"),
    ("CONFIG_EXFAT_FS", "any",
     "/mnt/t7 is exFAT and is where diagnostics are written; without this the "
     "mount unit fails and the whole diag pipeline is silently dead"),
    ("CONFIG_SQUASHFS_ZSTD", "any", "snap mounts fail: 'Filesystem uses zstd compression'"),
    ("CONFIG_SQUASHFS_XZ", "any", "snap mounts fail: 'Filesystem uses xz compression'"),
    ("CONFIG_SQUASHFS_LZO", "any", "snap mounts fail: 'Filesystem uses lzo compression'"),
    ("CONFIG_VFAT_FS", "any",
     "the ESP is the only writable surface that survives the root disk going "
     "offline; diagnostics are delivered through it"),
    ("CONFIG_PSTORE", "y", "no console log survives a disk that vanishes mid-boot"),
    ("CONFIG_PSTORE_RAM", "y",
     "ramoops needs to be built in to capture early boot; as a module it only "
     "starts recording once udev loads it"),
]

SH_BUILTINS = {
    "cd", "echo", "printf", "read", "test", "[", "set", "unset", "export",
    "eval", "exec", "exit", "return", "shift", "trap", "wait", "umask",
    "ulimit", "times", "type", "command", "local", "break", "continue",
    ".", ":", "true", "false", "getopts", "hash", "pwd", "kill", "jobs",
    "fg", "bg", "alias", "unalias", "source", "let", "declare", "readonly",
}
SH_KEYWORDS = {
    "if", "then", "else", "elif", "fi", "for", "while", "until", "do",
    "done", "case", "esac", "in", "function", "select", "time", "{", "}",
    "!", "(", ")", "[[", "]]",
}

FINDINGS = []


def finding(kind, sev, where, msg, detail=""):
    FINDINGS.append((kind, sev, where, msg, detail))


def unpack(initrd, dest):
    with open(initrd, "rb") as f:
        magic = f.read(8)
    if magic[:4] == b"\x28\xb5\x2f\xfd":
        dec = ["zstd", "-dc"]
    elif magic[:2] == b"\x1f\x8b":
        dec = ["gzip", "-dc"]
    elif magic[:6] == b"\xfd7zXZ\x00":
        dec = ["xz", "-dc"]
    else:
        sys.exit(f"unrecognised initramfs compression: {magic[:8]!r}")
    p1 = subprocess.Popen(dec + [initrd], stdout=subprocess.PIPE)
    p2 = subprocess.Popen(["cpio", "-idm", "--quiet"], stdin=p1.stdout, cwd=dest,
                          stderr=subprocess.DEVNULL)
    p1.stdout.close()
    p2.communicate()
    return p2.returncode == 0


def read_config(path):
    cfg = {}
    if not os.path.exists(path):
        return cfg
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        m = re.match(r"^(CONFIG_\w+)=(.*)$", line)
        if m:
            cfg[m.group(1)] = m.group(2).strip('"')
        else:
            m = re.match(r"^# (CONFIG_\w+) is not set$", line)
            if m:
                cfg[m.group(1)] = None
    return cfg


def check_fw_compress(root, cfg):
    exts = defaultdict(list)
    for base in ("lib/firmware", "usr/lib/firmware"):
        d = os.path.join(root, base)
        if not os.path.isdir(d):
            continue
        for dirpath, _, files in os.walk(d):
            for fn in files:
                rel = os.path.relpath(os.path.join(dirpath, fn), d)
                if fn.endswith(".zst"):
                    exts["zst"].append(rel)
                elif fn.endswith(".xz"):
                    exts["xz"].append(rel)
    if not exts:
        return
    have_any = cfg.get("CONFIG_FW_LOADER_COMPRESS") == "y"
    for ext, sym in (("zst", "CONFIG_FW_LOADER_COMPRESS_ZSTD"),
                     ("xz", "CONFIG_FW_LOADER_COMPRESS_XZ")):
        files = sorted(set(exts.get(ext, [])))
        if not files:
            continue
        if have_any and cfg.get(sym) == "y":
            continue
        finding("FW-COMPRESS", "BUG", "initramfs",
                f"{len(files)} .{ext} firmware files present but "
                f"{'CONFIG_FW_LOADER_COMPRESS' if not have_any else sym} is not set",
                "request_firmware() will return -ENOENT for all of them; e.g. "
                + ", ".join(files[:3]))


def check_mod_compress(root, cfg):
    comp = []
    for dirpath, _, files in os.walk(root):
        for fn in files:
            if fn.endswith((".ko.zst", ".ko.xz", ".ko.gz")):
                comp.append(fn)
    if not comp:
        return
    if cfg.get("CONFIG_MODULE_DECOMPRESS") == "y":
        return
    finding("MOD-COMPRESS", "SUSPECT", "initramfs",
            f"{len(comp)} compressed modules but CONFIG_MODULE_DECOMPRESS is not set",
            "userspace modprobe can still decompress; the kernel cannot")


def external_commands(text):
    """
    Words in command position in a POSIX shell script.

    Getting this wrong in the noisy direction is worse than useless: the first
    version reported the *loop variable* of `for VAR in` and every element of a
    multi-line word list as missing commands, because it split on newlines
    without joining backslash continuations. A checker nobody believes is a
    checker nobody runs.
    """
    # Mask quoted spans BEFORE anything else. Separators inside strings are
    # not separators: `echo "load; a .zst present"` was being split on that
    # semicolon and reporting `a` as a missing command. Masking with NULs
    # keeps offsets and the quote delimiters intact.
    def _mask(m):
        s = m.group(0)
        return s[0] + "\x00" * (len(s) - 2) + s[-1]

    text = re.sub(r'"(?:[^"\\]|\\.)*"', _mask, text)
    text = re.sub(r"'[^']*'", _mask, text)
    text = re.sub(r"#[^\n]*", "", text)
    text = re.sub(r"\\\n\s*", " ", text)                 # join continuations

    defined = set(re.findall(r"^\s*(\w+)\s*\(\)", text, re.M))
    assigned = set(re.findall(r"(?:^|[;&|]|\s)(\w+)=", text))
    assigned |= set(re.findall(r"\bfor\s+(\w+)\s+in\b", text))

    # A `for x in a b c; do` header is a word list, not commands. Same for
    # `case x in`. Drop the headers wholesale.
    text = re.sub(r"\bfor\s+\w+\s+in\b[^;\n]*", " ", text)
    text = re.sub(r"\bcase\s+\S+\s+in\b", " ", text)

    cmds = {}
    for chunk in re.split(r"[\n;]+|&&|\|\||[|&]|\$\(|`", text):
        raw = chunk.strip()
        chunk = raw
        # leading redirections and inline VAR=val prefixes
        chunk = re.sub(r"^(?:[0-9]?[<>]+\s*\S+\s*)+", "", chunk)
        while True:
            m = re.match(r"^(?:!|\{|\(|\)|if|then|else|elif|fi|do|done|while|"
                         r"until|esac|time)\s+", chunk)
            if not m:
                break
            chunk = chunk[m.end():]
        while re.match(r"^\w+=", chunk):
            chunk = re.sub(r"^\w+=(?:\"[^\"]*\"|'[^']*'|\S*)\s*", "", chunk)
        m = re.match(r"^([A-Za-z_][\w.-]*)(?:\s|$)", chunk)
        if not m:
            continue
        word = m.group(1)
        if (word in SH_BUILTINS or word in SH_KEYWORDS
                or word in defined or word in assigned):
            continue
        cmds.setdefault(word, raw[:70])
    return cmds


SELF_TEST = r"""
sp11_log() { echo "$*" > /dev/kmsg; }
sp11_collect() {
    for sp11_p in \
        lib/firmware/qcom/gen70500_sqe.fw \
        lib/firmware/qca/hmtbtfw20.tlv ; do
        for sp11_s in "" .zst .xz; do
            [ -e "$sp11_p$sp11_s" ] && echo present
        done
    done
    sz=$(du -k "$f" | cut -f1)
    ls -l "$d" 2>&1 | head -40
    cp -f "$f" "$out/${f##*/}"
    echo "name can ever load; a .zst or .xz present alone means -ENOENT."
    basename "$f"
    sync
}
"""
SELF_TEST_EXPECT = {"du", "cut", "head", "basename", "sync"}
# `a` comes from a semicolon INSIDE a quoted string; `zst` from the same line.
SELF_TEST_REJECT = {"sp11_p", "sp11_s", "sz", "f", "d", "out", "a", "zst",
                    "lib/firmware/qcom/gen70500_sqe.fw"}


def self_test():
    got = set(external_commands(SELF_TEST))
    missing = SELF_TEST_EXPECT - got
    spurious = SELF_TEST_REJECT & got
    print("external_commands self-test")
    print(f"  detected: {', '.join(sorted(got))}")
    ok = True
    if missing:
        print(f"  FAIL missed: {', '.join(sorted(missing))}")
        ok = False
    if spurious:
        print(f"  FAIL spurious: {', '.join(sorted(spurious))}")
        ok = False
    if ok:
        print("  ok: finds the five tools that were actually missing from the "
              "initramfs, and no loop variables or word-list entries")
    return 0 if ok else 1


def check_hooks(root):
    hookdir = os.path.join(root, "usr/lib/dracut/hooks")
    if not os.path.isdir(hookdir):
        return
    present = set()
    for base in ("bin", "sbin", "usr/bin", "usr/sbin"):
        d = os.path.join(root, base)
        if os.path.isdir(d):
            present.update(os.listdir(d))

    for dirpath, _, files in os.walk(hookdir):
        for fn in sorted(files):
            if not fn.endswith(".sh"):
                continue
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, root)
            text = open(p, encoding="utf-8", errors="replace").read()

            found = external_commands(text)
            missing = sorted(c for c in found if c not in present)
            if missing:
                where = "; ".join(f"{c} <- `{found[c]}`" for c in missing[:4])
                finding("HOOK-TOOLS", "BUG", rel,
                        f"calls {len(missing)} command(s) absent from the initramfs: "
                        + ", ".join(missing),
                        "a guard built on a missing command fails open and "
                        "reports success while doing nothing | " + where)

            for i, line in enumerate(text.splitlines(), 1):
                s = line.split("#", 1)[0]
                if re.search(r"(^|[;&|]\s*)exit\b", s):
                    finding("HOOK-EXIT", "BUG", f"{rel}:{i}",
                            "live `exit` in a sourced hook",
                            "dracut sources hooks; exit aborts the calling "
                            "script before its remaining source_hook calls")

            r = subprocess.run(["sh", "-n", p], capture_output=True, text=True)
            if r.returncode != 0:
                finding("HOOK-SYNTAX", "BUG", rel, "not valid POSIX shell",
                        r.stderr.strip()[:200])


def check_config_req(cfg):
    for sym, want, why in CONFIG_REQ:
        val = cfg.get(sym)
        if val is None:
            finding("CONFIG-REQ", "BUG", sym, "not set", why)
        elif want == "y" and val != "y":
            finding("CONFIG-REQ", "SUSPECT", sym, f"is '{val}', wanted 'y'", why)


SEV = {"BUG": 0, "SUSPECT": 1, "HINT": 2}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--initrd")
    ap.add_argument("--config")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if not args.config:
        ap.error("--config is required unless --self-test")

    cfg = read_config(args.config)
    if not cfg:
        sys.exit(f"no config read from {args.config}")

    tmp = None
    if args.initrd:
        tmp = tempfile.mkdtemp(prefix="initrd-audit.")
        if not unpack(args.initrd, tmp):
            sys.exit("failed to unpack initramfs")
        check_fw_compress(tmp, cfg)
        check_mod_compress(tmp, cfg)
        check_hooks(tmp)
    check_config_req(cfg)

    rows = sorted(FINDINGS, key=lambda f: (SEV.get(f[1], 9), f[0], f[2]))
    counts = defaultdict(int)
    for _, sev, *_ in rows:
        counts[sev] += 1
    print("initrd-audit")
    print(f"  {counts['BUG']} BUG, {counts['SUSPECT']} SUSPECT\n")
    last = None
    for kind, sev, where, msg, detail in rows:
        if kind != last:
            print(f"--- {kind} ---")
            last = kind
        print(f"  [{sev}] {where}")
        print(f"         {msg}")
        if detail:
            print(f"         {detail}")

    if tmp and not args.keep:
        shutil.rmtree(tmp, ignore_errors=True)
    elif tmp:
        print(f"\n  unpacked at {tmp}")
    return 1 if counts["BUG"] else 0


if __name__ == "__main__":
    sys.exit(main())
