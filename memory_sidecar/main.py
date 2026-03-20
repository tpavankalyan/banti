# memory_sidecar/main.py
import asyncio, os
from dotenv import load_dotenv

load_dotenv()


async def startup():
    from socket_server import set_startup_state
    set_startup_state(ready=False, error=None)
    from identity import init_identity
    try:
        await init_identity()
        from memory import init_memory
        await init_memory()
        set_startup_state(ready=True, error=None)
    except Exception as exc:
        set_startup_state(ready=False, error=str(exc))
        raise


if __name__ == "__main__":
    from socket_server import SocketServer, set_startup_state

    # Start socket server immediately so Swift health checks succeed while models load.
    set_startup_state(ready=False, error=None)
    server = SocketServer()
    print("[sidecar] listening on /tmp/banti_memory.sock")

    # Run startup on the same async loop used for request handlers.
    server.run_coro(startup())

    server.serve_forever()
