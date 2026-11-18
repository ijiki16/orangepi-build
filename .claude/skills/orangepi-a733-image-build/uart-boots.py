#!/usr/bin/env python3
"""Save the Orange Pi 4 Pro serial console to readable log files, one file per boot.

Files go to boots/ next to this script:
    boot-YYYYMMDD-HHMMSS.log       one board boot
    boot-...-part2.log             the same boot, continued after the size limit
    attached-YYYYMMDD-HHMMSS.log   output heard before the first boot marker
    latest.log                     link to the file being written

The logger only reads the port. It reconnects when the USB adapter returns.
"""
import argparse
import datetime
import fcntl
import os
import re
import sys
import time

BOOT_MARKER = "HELLO! BOOT0 is starting!"
ANSI = re.compile(r"\x1b(\[[0-9;?]*[ -/]*[@-~]|[@-Z\\^_]|\][^\x07]*\x07)")
UNPRINTABLE = re.compile(r"[^\t\x20-\x7e]")
LONGEST_LINE = 4096  # bytes; a flood without newlines must still reach the file
IDLE_FLUSH = 1.0  # seconds; prompts such as "login:" have no newline


def clean(raw):
    text = raw.decode("utf-8", "replace")
    return UNPRINTABLE.sub("", ANSI.sub("", text)).rstrip()


class BootFiles:
    def __init__(self, directory, max_bytes):
        self.directory = directory
        self.max_bytes = max_bytes
        self.file = None
        self.base = None
        self.part = 1
        self.size = 0
        os.makedirs(directory, exist_ok=True)

    def _open(self, name):
        path = os.path.join(self.directory, name + ".log")
        suffix = 1
        while os.path.exists(path):
            suffix += 1
            path = os.path.join(self.directory, f"{name}-{suffix}.log")
        if self.file:
            self.file.close()
        self.file = open(path, "w", buffering=1, encoding="ascii")
        self.size = 0
        link = os.path.join(self.directory, ".latest.tmp")
        if os.path.lexists(link):
            os.unlink(link)
        os.symlink(os.path.basename(path), link)
        os.replace(link, os.path.join(self.directory, "latest.log"))

    def start(self, kind):
        self.base = f"{kind}-{datetime.datetime.now():%Y%m%d-%H%M%S}"
        self.part = 1
        self._open(self.base)

    def write(self, text):
        if self.file is None:
            self.start("attached")
        elif self.size >= self.max_bytes:
            self.part += 1
            self._open(f"{self.base}-part{self.part}")
        line = f"{datetime.datetime.now():%H:%M:%S.%f}"[:-3] + "  " + text + "\n"
        self.file.write(line)
        self.size += len(line)

    def line(self, raw):
        text = clean(raw)
        if not text:
            return
        if BOOT_MARKER in text:
            self.start("boot")
        self.write(text)

    def note(self, text):
        if self.file is not None:
            self.write(f"### {text}")


class LineSplitter:
    def __init__(self, files):
        self.files = files
        self.pending = b""
        self.last_data = time.monotonic()

    def feed(self, data):
        self.pending += data
        self.last_data = time.monotonic()
        *lines, self.pending = self.pending.split(b"\n")
        for raw in lines:
            self.files.line(raw)
        if len(self.pending) >= LONGEST_LINE:
            self.flush()

    def flush(self):
        if self.pending:
            self.files.line(self.pending)
            self.pending = b""

    def idle(self):
        if self.pending and time.monotonic() - self.last_data >= IDLE_FLUSH:
            self.flush()


def replay(path, files):
    splitter = LineSplitter(files)
    with open(path, "rb") as source:
        while chunk := source.read(4096):
            splitter.feed(chunk)
    splitter.flush()


def listen(port, baud, files):
    import serial

    splitter = LineSplitter(files)
    connected = False
    while True:
        try:
            with serial.Serial(port, baud, timeout=0.2) as link:
                if connected is False:
                    files.note(f"listening on {port}")
                connected = True
                while True:
                    data = link.read(4096)
                    if data:
                        splitter.feed(data)
                    else:
                        splitter.idle()
        except (serial.SerialException, OSError):
            splitter.flush()
            if connected:
                files.note(f"{port} disconnected, waiting for it to return")
            connected = None
            time.sleep(2)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", default="/dev/ttyUSB0")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--dir", default=os.path.join(here, "boots"))
    parser.add_argument("--max-mb", type=float, default=5, help="start a new part after this size")
    parser.add_argument("--replay", help="process a saved raw log instead of the serial port")
    args = parser.parse_args()

    files = BootFiles(args.dir, int(args.max_mb * 1024 * 1024))
    if args.replay:
        replay(args.replay, files)
        return 0

    lock = open(os.path.join(args.dir, ".lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("uart-boots is already running", file=sys.stderr)
        return 1
    try:
        listen(args.port, args.baud, files)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
