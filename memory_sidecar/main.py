# memory_sidecar/main.py
import asyncio, os
from dotenv import load_dotenv

load_dotenv()


async def startup():
    from identity import init_identity
    await init_identity()
    from memory import init_memory
    await init_memory()


if __name__ == "__main__":
    asyncio.run(startup())
    from socket_server import SocketServer
    server = SocketServer()
    print("[sidecar] listening on /tmp/banti_memory.sock")
    server.serve_forever()
