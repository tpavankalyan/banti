# memory_sidecar/tests/test_voice.py
import pytest
import base64
import numpy as np
from unittest.mock import patch, MagicMock
from httpx import AsyncClient, ASGITransport

# 3 seconds of silence as PCM Int16 LE 16kHz mono
SILENT_3S_PCM_B64 = base64.b64encode(bytes(16000 * 3 * 2)).decode()

@pytest.fixture
def app_with_mock_voice(tmp_path):
    import os
    os.environ["BANTI_DB_PATH"] = str(tmp_path / "test.db")
    from db import init_db
    init_db(str(tmp_path / "test.db"))

    with patch("identity.VOICE_MODEL") as mock_voice_model:
        mock_voice_model.return_value = np.random.rand(256).astype(np.float32)
        from main import create_app
        yield create_app(testing=False), tmp_path

async def test_voice_unknown_speaker_returns_new_person_id(app_with_mock_voice):
    app, _ = app_with_mock_voice
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/identity/voice", json={
            "pcm_b64": SILENT_3S_PCM_B64,
            "deepgram_speaker_id": 0,
            "session_id": "voice-session-1"
        })
    assert response.status_code == 200
    data = response.json()
    assert data["matched"] == False
    assert data["person_id"].startswith("p_")

async def test_voice_same_speaker_matches_on_second_call(app_with_mock_voice):
    app, _ = app_with_mock_voice
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        r1 = await client.post("/identity/voice", json={
            "pcm_b64": SILENT_3S_PCM_B64,
            "deepgram_speaker_id": 1,
            "session_id": "voice-session-2"
        })
        r2 = await client.post("/identity/voice", json={
            "pcm_b64": SILENT_3S_PCM_B64,
            "deepgram_speaker_id": 1,
            "session_id": "voice-session-2"
        })
    assert r1.json()["person_id"] == r2.json()["person_id"]
    assert r2.json()["matched"] == True

async def test_voice_without_hf_token_returns_503(tmp_path):
    import os
    os.environ["BANTI_DB_PATH"] = str(tmp_path / "test.db")
    from db import init_db
    init_db(str(tmp_path / "test.db"))

    with patch("identity.VOICE_MODEL", None):
        from main import create_app
        app = create_app(testing=False)
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post("/identity/voice", json={
                "pcm_b64": SILENT_3S_PCM_B64,
                "deepgram_speaker_id": 0,
                "session_id": "voice-session-3"
            })
    assert response.status_code == 503
    assert "voice identity disabled" in response.json()["detail"].lower()
