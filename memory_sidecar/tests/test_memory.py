# memory_sidecar/tests/test_memory.py
import pytest
import json
from unittest.mock import patch, AsyncMock, MagicMock
from httpx import AsyncClient, ASGITransport

SAMPLE_SNAPSHOT = json.dumps({
    "speech": {"transcript": "Hello world", "resolvedName": "Alice",
                "isFinal": True, "confidence": 0.95,
                "updatedAt": "2026-03-19T10:00:00Z"},
    "activity": {"description": "typing", "updatedAt": "2026-03-19T10:00:00Z"}
})

EMPTY_SNAPSHOT = "{}"

@pytest.fixture
def app_with_mock_memory():
    with patch("memory.GRAPHITI") as mock_graphiti, \
         patch("memory.MEM0") as mock_mem0:
        mock_graphiti.add_episode = AsyncMock()
        mock_mem0.add = MagicMock()
        from main import create_app
        yield create_app(testing=False), mock_graphiti, mock_mem0

async def test_ingest_calls_graphiti_add_episode(app_with_mock_memory):
    app, mock_graphiti, _ = app_with_mock_memory
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/memory/ingest", json={
            "snapshot_json": SAMPLE_SNAPSHOT,
            "wall_ts": "2026-03-19T10:00:00Z"
        })
    assert response.status_code == 200
    mock_graphiti.add_episode.assert_called_once()

async def test_ingest_skips_empty_snapshot(app_with_mock_memory):
    app, mock_graphiti, _ = app_with_mock_memory
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/memory/ingest", json={
            "snapshot_json": EMPTY_SNAPSHOT,
            "wall_ts": "2026-03-19T10:00:00Z"
        })
    assert response.status_code == 200
    assert response.json()["skipped"] == True
    mock_graphiti.add_episode.assert_not_called()

def test_snapshot_to_episode_extracts_speech():
    from memory import snapshot_to_episode
    from datetime import datetime
    snap = {"speech": {"transcript": "Hello Alice", "resolvedName": "Bob"}}
    episode = snapshot_to_episode(snap, datetime.now())
    assert "Bob" in episode
    assert "Hello Alice" in episode

def test_snapshot_to_episode_returns_none_for_empty():
    from memory import snapshot_to_episode
    from datetime import datetime
    episode = snapshot_to_episode({}, datetime.now())
    assert episode is None

def test_snapshot_to_episode_handles_missing_resolved_name():
    from memory import snapshot_to_episode
    from datetime import datetime
    snap = {"speech": {"transcript": "Something was said"}}
    episode = snapshot_to_episode(snap, datetime.now())
    assert "unknown speaker" in episode

async def test_query_returns_answer(app_with_mock_memory):
    app, _, mock_mem0 = app_with_mock_memory
    mock_mem0.search.return_value = [
        {"memory": "Alice is a software engineer", "score": 0.95}
    ]
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/memory/query", json={"q": "who is Alice?"})
    assert response.status_code == 200
    data = response.json()
    assert "answer" in data

async def test_query_returns_empty_answer_when_mem0_disabled(tmp_path):
    with patch("memory.MEM0", None), patch("memory.GRAPHITI", None):
        from main import create_app
        app = create_app(testing=False)
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post("/memory/query", json={"q": "anything"})
    assert response.status_code == 200
    assert response.json()["answer"] == ""

async def test_reflect_returns_summary(app_with_mock_memory):
    app, _, _ = app_with_mock_memory
    snapshots = [SAMPLE_SNAPSHOT, SAMPLE_SNAPSHOT]
    with patch("memory.reflect_memory", new_callable=AsyncMock) as mock_reflect:
        mock_reflect.return_value = {"summary": "User was coding"}
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post("/memory/reflect", json={"snapshots": snapshots})
    assert response.status_code == 200
    assert "summary" in response.json()
