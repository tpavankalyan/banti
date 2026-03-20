import socket, msgpack, threading, os, time, pytest

SOCK_PATH = "/tmp/banti_test.sock"

def test_health_ping():
    """Start the socket server, send a health ping, expect pong."""
    from socket_server import SocketServer
    server = SocketServer(sock_path=SOCK_PATH, testing=True)
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    time.sleep(0.05)

    sock = socket.socket(socket.AF_UNIX)
    sock.connect(SOCK_PATH)
    payload = msgpack.packb({"method": "health"})
    length = len(payload).to_bytes(4, "big")
    sock.sendall(length + payload)
    resp_len = int.from_bytes(sock.recv(4), "big")
    resp = msgpack.unpackb(sock.recv(resp_len))
    sock.close()
    server.stop()
    assert resp == {"status": "ok"}
