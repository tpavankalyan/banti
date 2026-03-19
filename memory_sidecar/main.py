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
            await init_identity()
            try:
                from memory import init_memory
                await init_memory()
            except ImportError:
                pass  # memory module not yet implemented
        yield
        # Shutdown: nothing to clean up yet

    app = FastAPI(title="banti memory sidecar", lifespan=lifespan)

    @app.get("/health")
    async def health():
        return {"status": "ok"}

    from fastapi import HTTPException
    from models import FaceRequest, IdentityResponse

    @app.post("/identity/face", response_model=IdentityResponse)
    async def identity_face(req: FaceRequest):
        import base64
        from identity import identify_face
        try:
            jpeg_bytes = base64.b64decode(req.jpeg_b64)
            person_id, name, confidence = identify_face(jpeg_bytes)
            return IdentityResponse(
                matched=confidence >= 0.6,
                person_id=person_id,
                name=name,
                confidence=confidence,
            )
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e))

    return app

app = create_app()

if __name__ == "__main__":
    import uvicorn
    port = int(os.getenv("MEMORY_SIDECAR_PORT", "7700"))
    uvicorn.run("main:app", host="127.0.0.1", port=port, reload=False)
