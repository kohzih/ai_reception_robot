#!/usr/bin/env python3
"""Run on the WSL Docker host to forward localhost to the Rails container."""

import argparse
import ipaddress
import json
import selectors
import socket
import socketserver
import subprocess
import sys
import time


def port_number(value):
    port = int(value)
    if not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError("port must be between 1 and 65535")
    return port


def container_address(container):
    result = subprocess.run(
        ["docker", "inspect", "--format", "{{json .NetworkSettings.Networks}}", container],
        check=True,
        capture_output=True,
        text=True,
        timeout=15,
    )
    networks = json.loads(result.stdout)
    candidates = [networks["bridge"]] if "bridge" in networks else list(networks.values())
    addresses = [item.get("IPAddress") for item in candidates if item.get("IPAddress")]
    if len(addresses) != 1:
        raise ValueError("cannot identify one container IPv4 address; check docker inspect")
    return str(ipaddress.IPv4Address(addresses[0]))


class Forwarder(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            with socket.create_connection(self.server.target, timeout=5) as upstream:
                upstream.settimeout(10)
                self.request.settimeout(10)
                with selectors.DefaultSelector() as selector:
                    selector.register(self.request, selectors.EVENT_READ, upstream)
                    selector.register(upstream, selectors.EVENT_READ, self.request)
                    last_activity = time.monotonic()
                    while selector.get_map():
                        ready = selector.select(timeout=1)
                        if not ready and time.monotonic() - last_activity > 120:
                            return
                        for key, _ in ready:
                            data = key.fileobj.recv(65536)
                            if data:
                                key.data.sendall(data)
                                last_activity = time.monotonic()
                            else:
                                selector.unregister(key.fileobj)
                                try:
                                    key.data.shutdown(socket.SHUT_WR)
                                except OSError:
                                    pass
        except OSError as error:
            print(f"Connection failed: {error}", file=sys.stderr, flush=True)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", default="pai_ros2")
    parser.add_argument("--listen-port", type=port_number, default=3000)
    parser.add_argument("--target-port", type=port_number, default=3000)
    parser.add_argument("--target-host", help="explicit target IP; normally obtained from Docker")
    args = parser.parse_args()
    try:
        target = args.target_host or container_address(args.container)
        with Server(("127.0.0.1", args.listen_port), Forwarder) as server:
            server.target = (target, args.target_port)
            print(
                f"http://localhost:{args.listen_port} -> {target}:{args.target_port}\n"
                "Keep this WSL terminal open. Press Ctrl+C to stop.\n"
                "Restart this command after the target container restarts.",
                flush=True,
            )
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                print("\nPort forwarding stopped.", flush=True)
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Cannot start forwarding: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
