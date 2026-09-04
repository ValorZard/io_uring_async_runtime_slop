#!/usr/bin/env python3
"""Exercise every echo client against every echo server on loopback."""

import argparse
import os
import socket
import subprocess
import sys
import time


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def run_pair(server_name, server, client_name, client):
    port = free_port()
    environment = os.environ.copy()
    environment.pop("IOUR_BENCH_CPUS", None)
    environment["SEASTAR_EXTRA_ARGS"] = "--smp=1 --memory=128M --idle-poll-time-us=0"
    process = subprocess.Popen(
        [server, str(port), "1"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=environment,
    )
    try:
        deadline = time.monotonic() + 15
        server_output = ""
        while "listening on port" not in server_output:
            if process.poll() is not None:
                raise RuntimeError(f"{server_name} exited before listening:\n{server_output}")
            if time.monotonic() >= deadline:
                raise RuntimeError(f"{server_name} did not start:\n{server_output}")
            line = process.stdout.readline()
            if line:
                server_output += line

        client_result = subprocess.run(
            [client, "127.0.0.1", str(port), "1", "2"],
            capture_output=True,
            text=True,
            env=environment,
            timeout=20,
        )
        server_tail, _ = process.communicate(timeout=20)
        server_output += server_tail
        if client_result.returncode != 0 or process.returncode != 0:
            raise RuntimeError(
                f"{server_name}/{client_name} failed "
                f"(server={process.returncode}, client={client_result.returncode})\n"
                f"server:\n{server_output}\nclient:\n{client_result.stdout}{client_result.stderr}"
            )
        if "frames exchanged 2" not in client_result.stdout:
            raise RuntimeError(f"{server_name}/{client_name} did not exchange two frames")
        print(f"ok: {server_name} server <-> {client_name} client")
    except BaseException:
        if process.poll() is None:
            process.kill()
            process.communicate()
        raise


def main():
    parser = argparse.ArgumentParser()
    for name in ("seastar", "tokio", "ada"):
        parser.add_argument(f"--{name}-server", required=True)
        parser.add_argument(f"--{name}-client", required=True)
    args = parser.parse_args()

    peers = (
        ("seastar", args.seastar_server, args.seastar_client),
        ("tokio", args.tokio_server, args.tokio_client),
        ("ada", args.ada_server, args.ada_client),
    )
    for server_name, server, _ in peers:
        for client_name, _, client in peers:
            run_pair(server_name, server, client_name, client)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"interoperability_check: {error}", file=sys.stderr)
        sys.exit(1)