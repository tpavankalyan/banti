# memory_sidecar/tests/test_face.py
import pytest
import base64
import numpy as np
from unittest.mock import patch, MagicMock
from httpx import AsyncClient, ASGITransport

TINY_JPEG_B64 = "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/xAAUAQEAAAAAAAAAAAAAAAAAAAAA/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEQMRAD8AJQAB/9k="

@pytest.fixture
def app_with_mock_identity(tmp_path):
    import os
    os.environ["BANTI_DB_PATH"] = str(tmp_path / "test.db")
    from db import init_db
    init_db(str(tmp_path / "test.db"))

    with patch("identity.FACE_APP") as mock_face_app:
        mock_face = MagicMock()
        mock_face.embedding = np.random.rand(512).astype(np.float32)
        mock_face_app.get.return_value = [mock_face]

        from main import create_app
        yield create_app(testing=False), tmp_path

async def test_face_unknown_returns_new_person_id(app_with_mock_identity):
    app, tmp_path = app_with_mock_identity
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/identity/face", json={
            "jpeg_b64": TINY_JPEG_B64,
            "session_id": "test-session-1"
        })
    assert response.status_code == 200
    data = response.json()
    assert data["matched"] == False
    assert data["person_id"].startswith("p_")
    assert data["name"] is None

async def test_face_same_person_matches_on_second_call(app_with_mock_identity):
    app, tmp_path = app_with_mock_identity
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        r1 = await client.post("/identity/face", json={
            "jpeg_b64": TINY_JPEG_B64,
            "session_id": "test-session-2"
        })
        r2 = await client.post("/identity/face", json={
            "jpeg_b64": TINY_JPEG_B64,
            "session_id": "test-session-2"
        })
    id1 = r1.json()["person_id"]
    id2 = r2.json()["person_id"]
    assert id1 == id2
    assert r2.json()["matched"] == True

async def test_face_no_faces_detected_returns_400(tmp_path):
    import os
    os.environ["BANTI_DB_PATH"] = str(tmp_path / "test.db")
    from db import init_db
    init_db(str(tmp_path / "test.db"))

    with patch("identity.FACE_APP") as mock_face_app:
        mock_face_app.get.return_value = []
        from main import create_app
        app = create_app(testing=False)
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post("/identity/face", json={
                "jpeg_b64": TINY_JPEG_B64,
                "session_id": "test-session-3"
            })
    assert response.status_code == 400
