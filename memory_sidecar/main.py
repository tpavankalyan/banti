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
    from models import FaceRequest, VoiceRequest, IdentityResponse

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

    @app.post("/identity/voice", response_model=IdentityResponse)
    async def identity_voice(req: VoiceRequest):
        import base64 as _base64
        from identity import identify_voice, VOICE_MODEL as _voice_model
        if _voice_model is None:
            raise HTTPException(status_code=503, detail="Voice identity disabled — HF_TOKEN missing")
        try:
            pcm_bytes = _base64.b64decode(req.pcm_b64)
            person_id, name, confidence = identify_voice(pcm_bytes)
            return IdentityResponse(
                matched=confidence >= 0.75,
                person_id=person_id,
                name=name,
                confidence=confidence,
            )
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e))

    from models import IngestRequest

    @app.post("/memory/ingest")
    async def memory_ingest(req: IngestRequest):
        from memory import ingest_snapshot
        from datetime import datetime
        wall_ts = datetime.fromisoformat(req.wall_ts.replace("Z", "+00:00"))
        result = await ingest_snapshot(req.snapshot_json, wall_ts)
        return result

    from models import QueryRequest, QueryResponse

    @app.post("/memory/query", response_model=QueryResponse)
    async def memory_query(req: QueryRequest):
        from memory import query_memory
        result = await query_memory(req.q, req.context_json)
        return QueryResponse(answer=result["answer"], sources=result.get("sources", []))

    from models import ReflectRequest, ReflectResponse

    @app.post("/memory/reflect", response_model=ReflectResponse)
    async def memory_reflect(req: ReflectRequest):
        from memory import reflect_memory
        result = await reflect_memory(req.snapshots)
        return ReflectResponse(summary=result.get("summary", ""))

    return app

app = create_app()

if __name__ == "__main__":
    import uvicorn
    port = int(os.getenv("MEMORY_SIDECAR_PORT", "7700"))
    uvicorn.run("main:app", host="127.0.0.1", port=port, reload=False)
