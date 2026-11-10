#!/usr/bin/env python3
"""Records raw adb replies for the UniversalKMCore tests (add-android-file-browser task 1.5).

    python3 -I scripts/adb-capture.py <serial> <name>

Talks to the adb server on 127.0.0.1:5037 the way the app does and writes, into
Tests/UniversalKMCoreTests/Fixtures/adb/<name>-*.bin, the raw sync streams after the request:
  features.txt     host-serial:<s>:features
  list.bin         LIST of a test folder the script makes in Download (see FILES) and removes again
  lis2.bin         LIS2 of that folder      (only if the device has ls_v2)
  list-denied.bin  LIST /data/              (not readable without root)
  recv.bin         RECV of the test file
  recv.txt         that file's content
Only the test folder is recorded: listings of the real storage would show the owner's apps and folders.
"""
import os
import socket
import struct
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Tests", "UniversalKMCoreTests", "Fixtures", "adb")
FOLDER = "/sdcard/Download/ukm-fixture"
PROBE = FOLDER + "/Привет мир.txt"
# Made in FOLDER: a folder, a file with a quote and a space, a hidden file.
FILES = "mkdir -p '%s/Sub folder' && printf 'x' > \"%s/it's.txt\" && touch '%s/.hidden'" % (FOLDER, FOLDER, FOLDER)
CONTENT = "UniversalKM fixture: Привет, adb!\n" * 3


def connect():
    s = socket.create_connection(("127.0.0.1", 5037), timeout=10)
    return s


def host(s, text):
    body = text.encode()
    s.sendall(b"%04x" % len(body) + body)
    status = recv_exact(s, 4)
    if status != b"OKAY":
        length = int(recv_exact(s, 4), 16)
        raise RuntimeError(recv_exact(s, length).decode())


def recv_exact(s, n):
    data = b""
    while len(data) < n:
        chunk = s.recv(n - len(data))
        if not chunk:
            raise RuntimeError("connection closed")
        data += chunk
    return data


def recv_all(s):
    data = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            return data
        data += chunk


def device(serial, service):
    s = connect()
    host(s, "host:transport:" + serial)
    host(s, service)
    return s


def sync_request(s, ident, path):
    p = path.encode()
    s.sendall(ident + struct.pack("<I", len(p)) + p)


def read_sync(s, kind):
    """Reads one complete sync reply and returns its raw bytes."""
    raw = b""
    while True:
        head = recv_exact(s, 4)
        raw += head
        if head == b"DENT":
            rest = recv_exact(s, 16); raw += rest
            raw += recv_exact(s, struct.unpack("<I", rest[12:16])[0])
        elif head == b"DNT2":
            rest = recv_exact(s, 72); raw += rest
            raw += recv_exact(s, struct.unpack("<I", rest[68:72])[0])
        elif head == b"DATA":
            rest = recv_exact(s, 4); raw += rest
            raw += recv_exact(s, struct.unpack("<I", rest)[0])
        elif head == b"DONE":
            raw += recv_exact(s, {"list": 16, "lis2": 72}.get(kind, 4))
            return raw
        elif head == b"FAIL":
            rest = recv_exact(s, 4); raw += rest
            raw += recv_exact(s, struct.unpack("<I", rest)[0])
            return raw
        else:
            raise RuntimeError("unexpected %r" % head)


def capture(serial, kind, ident, path):
    s = device(serial, "sync:")
    sync_request(s, ident, path)
    raw = read_sync(s, kind)
    s.sendall(b"QUIT" + struct.pack("<I", 0))
    s.close()
    return raw


def shell(serial, command):
    s = device(serial, "shell:" + command)
    out = recv_all(s)
    s.close()
    return out


def main():
    serial, name = sys.argv[1], sys.argv[2]
    os.makedirs(ROOT, exist_ok=True)
    out = lambda suffix: os.path.join(ROOT, "%s-%s" % (name, suffix))

    s = connect()
    host(s, "host-serial:%s:features" % serial)
    length = int(recv_exact(s, 4), 16)
    features = recv_exact(s, length).decode()
    s.close()
    open(out("features.txt"), "w").write(features)

    shell(serial, "rm -rf '%s' && %s && printf '%s' > '%s'" % (FOLDER, FILES, CONTENT.replace("'", ""), PROBE))
    try:
        open(out("list.bin"), "wb").write(capture(serial, "list", b"LIST", FOLDER + "/"))
        if "ls_v2" in features.split(","):
            open(out("lis2.bin"), "wb").write(capture(serial, "lis2", b"LIS2", FOLDER + "/"))
        open(out("list-denied.bin"), "wb").write(capture(serial, "list", b"LIST", "/data/"))
        open(out("recv.bin"), "wb").write(capture(serial, "recv", b"RECV", PROBE))
        open(out("recv.txt"), "w").write(CONTENT)
    finally:
        shell(serial, "rm -rf '%s'" % FOLDER)
    print("wrote", ", ".join(sorted(f for f in os.listdir(ROOT) if f.startswith(name + "-"))))


if __name__ == "__main__":
    main()
