# memory_sidecar/socket_server.py
import socket, os, struct, threading, inspect
import msgpack
from datetime import timezone

DISPATCH = {}

def handler(method):
    def decorator(fn):
        DISPATCH[method] = fn
        return fn
    return decorator


class SocketServer:
    def __init__(self, sock_path="/tmp/banti_memory.sock", testing=False):
        self.sock_path = sock_path
        self._stop = threading.Event()
        self.testing = testing
        if os.path.exists(sock_path):
            os.unlink(sock_path)
        self._sock = socket.socket(socket.AF_UNIX)
        self._sock.bind(sock_path)
        self._sock.listen(5)
        self._sock.settimeout(0.5)

    def serve_forever(self):
        while not self._stop.is_set():
            try:
                conn, _ = self._sock.accept()
                threading.Thread(target=self._handle_conn, args=(conn,), daemon=True).start()
            except socket.timeout:
                continue

    def stop(self):
        self._stop.set()
        self._sock.close()
        if os.path.exists(self.sock_path):
            os.unlink(self.sock_path)

    def _recv_exact(self, conn, n):
        data = b""
        while len(data) < n:
            chunk = conn.recv(n - len(data))
            if not chunk:
                return None
            data += chunk
        return data

    def _handle_conn(self, conn):
        try:
            raw_len = self._recv_exact(conn, 4)
            if raw_len is None:
                return
            length = struct.unpack(">I", raw_len)[0]
            data = b""
            while len(data) < length:
                chunk = conn.recv(length - len(data))
                if not chunk:
                    return
                data += chunk
            request = msgpack.unpackb(data, raw=False)
            method = request.get("method", "")
            fn = DISPATCH.get(method)
            if fn:
                import asyncio
                if inspect.iscoroutinefunction(fn):
                    result = asyncio.run(fn(request))
                else:
                    result = fn(request)
            else:
                result = {"error": f"unknown method: {method}"}
            response = msgpack.packb(result)
            conn.sendall(struct.pack(">I", len(response)) + response)
        except Exception as e:
            print(f"[socket] error: {e}")
            try:
                error_resp = msgpack.packb({"error": str(e)})
                conn.sendall(struct.pack(">I", len(error_resp)) + error_resp)
            except Exception:
                pass  # best-effort
        finally:
            conn.close()


@handler("health")
def health(_req):
    return {"status": "ok"}


@handler("identify_face")
async def identify_face(req):
    import base64
    from identity import identify_face as _identify
    try:
        jpeg = base64.b64decode(req["jpeg_b64"])
        person_id, name, confidence = _identify(jpeg)
        return {"matched": confidence >= 0.6, "person_id": person_id,
                "name": name, "confidence": confidence}
    except Exception as e:
        return {"error": str(e)}


@handler("identify_voice")
async def identify_voice(req):
    import base64
    from identity import identify_voice as _identify_voice
    try:
        pcm_bytes = base64.b64decode(req["pcm_b64"])
        person_id, name, confidence = _identify_voice(pcm_bytes)
        return {"matched": confidence >= 0.75, "person_id": person_id,
                "name": name, "confidence": confidence}
    except Exception as e:
        return {"error": str(e)}


@handler("query_memory")
async def query_memory(req):
    from memory import query_memory as _query
    # Returns {"answer": str, "sources": list}
    result = await _query(req.get("q", ""), req.get("context_json"))
    return result


@handler("store_episode")
async def store_episode(req):
    from memory import ingest_snapshot
    from datetime import datetime
    wall_ts_str = req.get("wall_ts")
    if wall_ts_str:
        wall_ts = datetime.fromisoformat(wall_ts_str.replace("Z", "+00:00"))
    else:
        wall_ts = datetime.now(timezone.utc)
    # Returns a dict
    result = await ingest_snapshot(req.get("snapshot_json", "{}"), wall_ts)
    return result


@handler("reflect")
async def reflect(req):
    from memory import reflect_memory
    # Returns {"summary": str}
    result = await reflect_memory(req.get("snapshots", []))
    return result


@handler("brain_decide")
async def brain_decide(req):
    from memory import brain_decide as _brain_decide
    from models import BrainDecideRequest
    # Build a BrainDecideRequest from the raw dict
    try:
        brain_req = BrainDecideRequest(**{k: v for k, v in req.items() if k != "method"})
        response = await _brain_decide(brain_req)
        return {"action": response.action, "text": response.text, "reason": response.reason}
    except Exception as e:
        return {"error": str(e)}
