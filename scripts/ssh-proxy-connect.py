#!/usr/bin/env python3
"""Tunnel SSH through an HTTP CONNECT proxy.

Used as SSH ProxyCommand to reach github.com from compute nodes
that only allow outbound traffic through an HTTP proxy.

Usage (in ~/.ssh/config):
    Host github.com
        ProxyCommand /path/to/ssh-proxy-connect.py PROXY_HOST PROXY_PORT %h %p
"""
import socket
import sys

def main():
    if len(sys.argv) != 5:
        print(f"Usage: {sys.argv[0]} PROXY_HOST PROXY_PORT TARGET_HOST TARGET_PORT", file=sys.stderr)
        sys.exit(1)

    proxy_host, proxy_port, target_host, target_port = sys.argv[1:]

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.connect((proxy_host, int(proxy_port)))
    sock.sendall(f"CONNECT {target_host}:{target_port} HTTP/1.1\r\nHost: {target_host}:{target_port}\r\n\r\n".encode())

    response = b""
    while b"\r\n\r\n" not in response:
        data = sock.recv(4096)
        if not data:
            print("Proxy closed connection", file=sys.stderr)
            sys.exit(1)
        response += data

    status_line = response.split(b"\r\n")[0].decode()
    if " 200 " not in status_line:
        print(f"Proxy error: {status_line}", file=sys.stderr)
        sys.exit(1)

    # Relay data between stdin/stdout and the socket
    import select
    import os

    stdin_fd = sys.stdin.buffer.fileno()
    stdout_fd = sys.stdout.buffer.fileno()
    sock_fd = sock.fileno()

    # Any leftover data after the HTTP response headers
    leftover = response.split(b"\r\n\r\n", 1)[1]
    if leftover:
        os.write(stdout_fd, leftover)

    try:
        while True:
            readable, _, _ = select.select([stdin_fd, sock_fd], [], [])
            for fd in readable:
                if fd == stdin_fd:
                    data = os.read(stdin_fd, 65536)
                    if not data:
                        return
                    sock.sendall(data)
                elif fd == sock_fd:
                    data = sock.recv(65536)
                    if not data:
                        return
                    os.write(stdout_fd, data)
    except (BrokenPipeError, ConnectionResetError, OSError):
        pass

if __name__ == "__main__":
    main()
