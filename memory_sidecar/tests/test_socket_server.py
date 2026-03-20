import socket, msgpack, struct, threading, os, time, pytest

SOCK_PATH = "/tmp/banti_test.sock"


def _recv_exact(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def _roundtrip(sock, request):
    payload = msgpack.packb(request)
    sock.sendall(struct.pack(">I", len(payload)) + payload)
    raw_len = _recv_exact(sock, 4)
    resp_len = int.from_bytes(raw_len, "big")
    return msgpack.unpackb(_recv_exact(sock, resp_len))


def test_health_ping():
    """Start the socket server, send a health ping, expect pong."""
    from socket_server import SocketServer
    server = SocketServer(sock_path=SOCK_PATH, testing=True)
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    time.sleep(0.05)

    sock = socket.socket(socket.AF_UNIX)
    try:
        sock.connect(SOCK_PATH)
        resp = _roundtrip(sock, {"method": "health"})
        assert resp == {"status": "ok"}
    finally:
        sock.close()
        server.stop()


def test_unknown_method_returns_error():
    """Unknown method should return a response dict with an 'error' key."""
    from socket_server import SocketServer
    server = SocketServer(sock_path=SOCK_PATH, testing=True)
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    time.sleep(0.05)

    sock = socket.socket(socket.AF_UNIX)
    try:
        sock.connect(SOCK_PATH)
        resp = _roundtrip(sock, {"method": "nonexistent"})
        assert "error" in resp
    finally:
        sock.close()
        server.stop()
