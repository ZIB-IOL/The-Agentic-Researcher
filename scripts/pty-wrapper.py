#!/usr/bin/env python3
"""
PTY wrapper to allocate a pseudo-TTY for Apptainer containers.
This solves the issue where interactive applications like Claude Code
need raw mode on stdin, which requires a proper TTY.

Features:
  - Non-blocking I/O on master PTY (prevents hangs when child stops reading)
  - Forwards SIGINT/SIGTERM/SIGHUP to child process
  - Force-quit on 5x Ctrl+C within 2 seconds (escape valve for hung processes)
  - Periodic child liveness check (detects zombie/exited child)
"""
import os
import sys
import pty
import tty
import time
import errno
import select
import termios
import struct
import fcntl
import signal

# Force-quit threshold: N presses of Ctrl+C within T seconds
FORCE_QUIT_COUNT = 5
FORCE_QUIT_WINDOW = 2.0

# How often to check if child is still alive (seconds)
CHILD_CHECK_INTERVAL = 1.0


def set_window_size(fd):
    """Copy the terminal window size to the PTY"""
    try:
        s = struct.pack('HHHH', 0, 0, 0, 0)
        size = fcntl.ioctl(sys.stdin.fileno(), termios.TIOCGWINSZ, s)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, size)
    except OSError:
        pass


def nonblock_write(fd, data):
    """Write data to a non-blocking fd, dropping bytes if buffer is full."""
    try:
        os.write(fd, data)
    except OSError as e:
        if e.errno == errno.EAGAIN:
            # PTY buffer full -- drop data rather than blocking the event loop.
            # This only happens when the child isn't reading (hung/busy).
            pass
        else:
            raise


def main():
    if len(sys.argv) < 2:
        print("Usage: pty-wrapper.py <command> [args...]", file=sys.stderr)
        sys.exit(1)

    # Spawn the command with a PTY
    pid, master_fd = pty.fork()

    if pid == 0:  # Child process
        os.execvp(sys.argv[1], sys.argv[1:])
    else:  # Parent process
        # Make master_fd non-blocking so writes never stall the event loop
        flags = fcntl.fcntl(master_fd, fcntl.F_GETFL)
        fcntl.fcntl(master_fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

        # Track Ctrl+C presses for force-quit detection
        ctrl_c_times = []

        # Forward signals to the child process
        def forward_signal(signum, frame):
            try:
                os.kill(pid, signum)
            except ProcessLookupError:
                pass

        # Handle window size changes
        def handle_sigwinch(signum, frame):
            try:
                set_window_size(master_fd)
            except OSError:
                pass

        signal.signal(signal.SIGWINCH, handle_sigwinch)
        signal.signal(signal.SIGINT, forward_signal)
        signal.signal(signal.SIGTERM, forward_signal)
        signal.signal(signal.SIGHUP, forward_signal)
        set_window_size(master_fd)

        # Set stdin to raw mode if it's a TTY
        old_settings = None
        if sys.stdin.isatty():
            old_settings = termios.tcgetattr(sys.stdin)
            tty.setraw(sys.stdin.fileno())

        try:
            while True:
                # Use timeout so we can periodically check child liveness
                try:
                    r, w, e = select.select(
                        [sys.stdin, master_fd], [], [], CHILD_CHECK_INTERVAL
                    )
                except (InterruptedError, select.error):
                    # select interrupted by signal, just continue
                    continue

                if not r:
                    # Timeout: check if child is still alive
                    try:
                        result = os.waitpid(pid, os.WNOHANG)
                        if result[0] != 0:
                            break  # Child exited
                    except ChildProcessError:
                        break  # Child already reaped
                    continue

                if sys.stdin in r:
                    data = os.read(sys.stdin.fileno(), 4096)
                    if data:
                        # Detect force-quit: 5x Ctrl+C within 2 seconds
                        if b'\x03' in data:
                            now = time.monotonic()
                            ctrl_c_times.append(now)
                            ctrl_c_times = [
                                t for t in ctrl_c_times
                                if now - t < FORCE_QUIT_WINDOW
                            ]
                            if len(ctrl_c_times) >= FORCE_QUIT_COUNT:
                                # Escalate: SIGTERM first, then SIGKILL
                                try:
                                    os.kill(pid, signal.SIGTERM)
                                    # Give child 1 second to exit gracefully
                                    for _ in range(10):
                                        time.sleep(0.1)
                                        try:
                                            result = os.waitpid(
                                                pid, os.WNOHANG
                                            )
                                            if result[0] != 0:
                                                break
                                        except ChildProcessError:
                                            break
                                    else:
                                        os.kill(pid, signal.SIGKILL)
                                except ProcessLookupError:
                                    pass
                                break
                        else:
                            ctrl_c_times.clear()

                        nonblock_write(master_fd, data)
                    else:
                        break  # stdin EOF

                if master_fd in r:
                    try:
                        data = os.read(master_fd, 4096)
                        if data:
                            os.write(sys.stdout.fileno(), data)
                            sys.stdout.flush()
                        else:
                            break  # EOF
                    except OSError as e:
                        if e.errno == errno.EAGAIN:
                            continue  # No data ready yet (non-blocking)
                        break  # Child process exited or real error

        finally:
            # Restore terminal settings
            if old_settings:
                termios.tcsetattr(sys.stdin, termios.TCSAFLUSH, old_settings)

            # Wait for child to exit
            try:
                _, status = os.waitpid(pid, 0)
                exit_code = (
                    os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1
                )
                sys.exit(exit_code)
            except ChildProcessError:
                sys.exit(1)


if __name__ == '__main__':
    main()
