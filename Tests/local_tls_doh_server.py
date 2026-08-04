#!/usr/bin/env python3
"""Small localhost TLS server used by the SecureTransport integration harness."""

import argparse
import pathlib
import socket
import ssl
import threading
import time


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--capture-dir", required=True)
    parser.add_argument("--sni-file", required=True)
    args = parser.parse_args()

    capture_dir = pathlib.Path(args.capture_dir)
    capture_dir.mkdir(parents=True, exist_ok=True)
    port_file = pathlib.Path(args.port_file)
    sni_file = pathlib.Path(args.sni_file)
    lock = threading.Lock()
    request_number = 0

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)

    def on_sni(_ssl_socket: ssl.SSLSocket, server_name: str, _context: ssl.SSLContext) -> None:
        with lock:
            with sni_file.open("a", encoding="utf-8") as output:
                output.write((server_name or "") + "\n")

    context.set_servername_callback(on_sni)

    def read_request(client: ssl.SSLSocket) -> bytes | None:
        data = bytearray()
        while b"\r\n\r\n" not in data:
            chunk = client.recv(4096)
            if not chunk:
                return None
            data.extend(chunk)
            if len(data) > 64 * 1024:
                return None
        header_end = data.index(b"\r\n\r\n") + 4
        header = bytes(data[:header_end])
        content_length = 0
        for line in header.split(b"\r\n"):
            if line.lower().startswith(b"content-length:"):
                content_length = int(line.split(b":", 1)[1].strip())
        while len(data) - header_end < content_length:
            chunk = client.recv(4096)
            if not chunk:
                return None
            data.extend(chunk)
        return bytes(data[:header_end + content_length])

    def serve(raw_client: socket.socket) -> None:
        nonlocal request_number
        try:
            with context.wrap_socket(raw_client, server_side=True) as client:
                client.settimeout(5)
                while True:
                    request = read_request(client)
                    if request is None:
                        return
                    with lock:
                        number = request_number
                        request_number += 1
                    (capture_dir / f"request-{number:04d}.bin").write_bytes(request)
                    delay = 2.0 if b"X-Test-Delay: 2" in request else 0.0
                    if delay:
                        time.sleep(delay)
                    response_body = b"\x12\x34\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00"
                    response = (
                        b"HTTP/1.1 200 OK\r\n"
                        b"Content-Type: application/dns-message\r\n"
                        + f"Content-Length: {len(response_body)}\r\n".encode("ascii")
                        + b"Connection: close\r\n\r\n"
                        + response_body
                    )
                    client.sendall(response)
        except (ConnectionError, OSError, ssl.SSLError, TimeoutError):
            return

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(16)
        listener.settimeout(0.25)
        port_file.write_text(str(listener.getsockname()[1]), encoding="ascii")
        while True:
            try:
                client, _ = listener.accept()
            except socket.timeout:
                continue
            threading.Thread(target=serve, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
