#!/usr/bin/env python3
"""TCP bridge from localhost:8124 to the Home Assistant VM."""

from __future__ import annotations

import argparse
import selectors
import socket
import socketserver
from collections.abc import Iterable


BUFFER_SIZE = 64 * 1024


class BridgeHandler(socketserver.BaseRequestHandler):
    target_host: str
    target_port: int

    def handle(self) -> None:
        with socket.create_connection(
            (self.target_host, self.target_port),
            timeout=10,
        ) as upstream:
            self.request.setblocking(False)
            upstream.setblocking(False)
            self._relay(self.request, upstream)

    @staticmethod
    def _relay(client: socket.socket, upstream: socket.socket) -> None:
        selector = selectors.DefaultSelector()
        sockets = {client, upstream}
        selector.register(client, selectors.EVENT_READ, upstream)
        selector.register(upstream, selectors.EVENT_READ, client)

        try:
            while sockets:
                for key, _ in selector.select():
                    source = key.fileobj
                    destination = key.data

                    try:
                        data = source.recv(BUFFER_SIZE)
                    except OSError:
                        data = b""

                    if data:
                        try:
                            destination.sendall(data)
                        except OSError:
                            return
                        continue

                    BridgeHandler._close_read_side(selector, sockets, source)
                    try:
                        destination.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
        finally:
            selector.close()

    @staticmethod
    def _close_read_side(
        selector: selectors.BaseSelector,
        sockets: set[socket.socket],
        source: socket.socket,
    ) -> None:
        try:
            selector.unregister(source)
        except (KeyError, ValueError):
            pass
        sockets.discard(source)


class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def parse_args(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen-host", default="0.0.0.0")
    parser.add_argument("--listen-port", type=int, default=8124)
    parser.add_argument("--target-host", default="192.168.1.5")
    parser.add_argument("--target-port", type=int, default=8123)
    return parser.parse_args(argv)


def main() -> None:
    args = parse_args()
    BridgeHandler.target_host = args.target_host
    BridgeHandler.target_port = args.target_port

    with ThreadedTCPServer((args.listen_host, args.listen_port), BridgeHandler) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
