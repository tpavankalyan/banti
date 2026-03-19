# memory_sidecar/main.py
import os
from contextlib import asynccontextmanager
from fastapi import FastAPI
from dotenv import load_dotenv

load_dotenv()

def create_app(testing: bool = False) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI):
        # Startup: initialize heavy models only in production
        if not testing:
            from identity import init_identity
            from memory import init_memory
            await init_identity()
            await init_memory()
        yield
        # Shutdown: nothing to clean up yet

    app = FastAPI(title="banti memory sidecar", lifespan=lifespan)

    @app.get("/health")
    async def health():
        return {"status": "ok"}

    # Routers registered in later tasks
    return app

app = create_app()

if __name__ == "__main__":
    import uvicorn
    port = int(os.getenv("MEMORY_SIDECAR_PORT", "7700"))
    uvicorn.run("main:app", host="127.0.0.1", port=port, reload=False)
