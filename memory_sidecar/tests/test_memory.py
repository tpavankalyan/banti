# memory_sidecar/tests/test_memory.py
import pytest
import json
import os
import sys
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

def test_snapshot_to_episode_returns_none_for_empty():
    from memory import snapshot_to_episode
    from datetime import datetime
    episode = snapshot_to_episode({}, datetime.now())
    assert episode is None

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

@pytest.mark.asyncio
async def test_socket_query_memory_person_id_returns_person_facts(tmp_path):
    db_path = tmp_path / "identity.db"
    with patch.dict(os.environ, {"BANTI_DB_PATH": str(db_path)}):
        from db import init_db, create_person, update_person_name
        init_db(str(db_path))
        person_id = create_person(str(db_path), display_name=None, face_embedding=None, voice_embedding=None)
        update_person_name(str(db_path), person_id, "Alice")

        stub_anthropic = MagicMock()
        stub_anthropic.AsyncAnthropic = MagicMock()
        stub_openai = MagicMock()
        stub_openai.AsyncOpenAI = MagicMock()
        stub_msgpack = MagicMock()
        sys.modules.pop("memory", None)
        with patch.dict(sys.modules, {"anthropic": stub_anthropic, "openai": stub_openai, "msgpack": stub_msgpack}):
            with patch("memory.GRAPHITI", None), patch("memory.MEM0") as mock_mem0:
                mock_mem0.search.return_value = [
                    {"memory": "likes chai"},
                    {"memory": "works on banti"},
                ]
                from socket_server import query_memory as socket_query_memory
                result = await socket_query_memory({"person_id": person_id})

        assert result["person_name"] == "Alice"
        assert result["facts"] == ["likes chai", "works on banti"]

@pytest.mark.asyncio
async def test_socket_query_memory_person_id_falls_back_to_self_memory(tmp_path):
    db_path = tmp_path / "identity.db"
    with patch.dict(os.environ, {"BANTI_DB_PATH": str(db_path)}):
        from db import init_db, create_person, update_person_name
        init_db(str(db_path))
        person_id = create_person(str(db_path), display_name=None, face_embedding=None, voice_embedding=None)
        update_person_name(str(db_path), person_id, "Alice")

        stub_anthropic = MagicMock()
        stub_anthropic.AsyncAnthropic = MagicMock()
        stub_openai = MagicMock()
        stub_openai.AsyncOpenAI = MagicMock()
        stub_msgpack = MagicMock()
        sys.modules.pop("memory", None)
        with patch.dict(sys.modules, {"anthropic": stub_anthropic, "openai": stub_openai, "msgpack": stub_msgpack}):
            with patch("memory.GRAPHITI", None), patch("memory.MEM0") as mock_mem0:
                mock_mem0.search.side_effect = [
                    [],
                    [{"memory": "Alice likes chai"}],
                ]
                from socket_server import query_memory as socket_query_memory
                result = await socket_query_memory({"person_id": person_id})

        assert result["person_name"] == "Alice"
        assert result["facts"] == ["Alice likes chai"]

@pytest.mark.asyncio
async def test_ingest_snapshot_accepts_plain_episode_text():
    from datetime import datetime
    stub_anthropic = MagicMock()
    stub_anthropic.AsyncAnthropic = MagicMock()
    stub_openai = MagicMock()
    stub_openai.AsyncOpenAI = MagicMock()
    sys.modules.pop("memory", None)
    with patch.dict(sys.modules, {"anthropic": stub_anthropic, "openai": stub_openai}):
        with patch("memory.GRAPHITI") as mock_graphiti, patch("memory.MEM0") as mock_mem0:
            mock_graphiti.add_episode = AsyncMock()
            mock_mem0.add = MagicMock()
            from memory import ingest_snapshot
            result = await ingest_snapshot("Pavan fixed the bug", datetime(2026, 3, 19, 10, 0, 0))

    assert result["skipped"] is False
    assert result["episode"] == "Pavan fixed the bug"
    mock_graphiti.add_episode.assert_called_once()
    mock_mem0.add.assert_any_call("Pavan fixed the bug", user_id="banti_self")

async def test_reflect_returns_summary(app_with_mock_memory):
    app, _, _ = app_with_mock_memory
    snapshots = [SAMPLE_SNAPSHOT, SAMPLE_SNAPSHOT]
    with patch("memory.reflect_memory", new_callable=AsyncMock) as mock_reflect:
        mock_reflect.return_value = {"summary": "User was coding"}
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post("/memory/reflect", json={"snapshots": snapshots})
    assert response.status_code == 200
    assert "summary" in response.json()

def test_anthropic_importable():
    import anthropic
    assert hasattr(anthropic, "AsyncAnthropic")

def test_brain_decide_request_defaults():
    from models import BrainDecideRequest
    req = BrainDecideRequest(snapshot_json="{}")
    assert req.recent_speech == []
    assert req.last_spoke_seconds_ago == 9999.0
    assert req.last_spoke_text is None

def test_proactive_decision_response_speak():
    from models import ProactiveDecisionResponse
    r = ProactiveDecisionResponse(action="speak", text="Hello!", reason="test")
    assert r.action == "speak"
    assert r.text == "Hello!"

def test_proactive_decision_response_silent_text_is_none():
    from models import ProactiveDecisionResponse
    r = ProactiveDecisionResponse(action="silent", reason="focused")
    assert r.text is None

def test_proactive_decision_response_rejects_invalid_action():
    from models import ProactiveDecisionResponse
    with pytest.raises(Exception):
        ProactiveDecisionResponse(action="shout", reason="bad")

@pytest.mark.asyncio
async def test_brain_decide_returns_silent_when_no_api_key():
    with patch.dict(os.environ, {"ANTHROPIC_API_KEY": ""}):
        from memory import brain_decide
        from models import BrainDecideRequest
        req = BrainDecideRequest(snapshot_json="{}", recent_speech=[])
        result = await brain_decide(req)
        assert result.action == "silent"
        assert result.text is None

@pytest.mark.asyncio
async def test_brain_decide_returns_speak_when_llm_says_speak():
    mock_response = MagicMock()
    mock_response.content = [MagicMock(text='{"action": "speak", "text": "You seem busy!", "reason": "test"}')]
    with patch("memory.GRAPHITI", None), patch("memory.MEM0", None):
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}):
            with patch("anthropic.AsyncAnthropic") as mock_cls:
                mock_client = MagicMock()
                mock_client.messages.create = AsyncMock(return_value=mock_response)
                mock_cls.return_value = mock_client
                from memory import brain_decide
                from models import BrainDecideRequest
                req = BrainDecideRequest(snapshot_json="{}", recent_speech=["hello"])
                result = await brain_decide(req)
                assert result.action == "speak"
                assert result.text == "You seem busy!"

@pytest.mark.asyncio
async def test_brain_decide_returns_silent_on_llm_error():
    with patch("memory.GRAPHITI", None), patch("memory.MEM0", None):
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}):
            with patch("anthropic.AsyncAnthropic") as mock_cls:
                mock_client = MagicMock()
                mock_client.messages.create = AsyncMock(side_effect=Exception("network error"))
                mock_cls.return_value = mock_client
                from memory import brain_decide
                from models import BrainDecideRequest
                req = BrainDecideRequest(snapshot_json="{}")
                result = await brain_decide(req)
                assert result.action == "silent"

@pytest.mark.asyncio
async def test_brain_decide_endpoint_returns_silent_when_no_key():
    import os
    env = {k: v for k, v in os.environ.items() if k != "ANTHROPIC_API_KEY"}
    with patch.dict(os.environ, env, clear=True):
        from main import create_app
        app = create_app(testing=True)
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post("/brain/decide", json={
                "snapshot_json": "{}",
                "recent_speech": []
            })
    assert response.status_code == 200
    data = response.json()
    assert data["action"] == "silent"
    assert data["text"] is None
    assert "reason" in data

@pytest.mark.asyncio
async def test_query_memory_uses_anthropic_when_key_present():
    """Verify query_memory calls Anthropic (not OpenAI) for answer fusion."""
    mock_response = MagicMock()
    mock_response.content = [MagicMock(text="Alice is a software engineer.")]
    with patch("memory.GRAPHITI", None):
        with patch("memory.MEM0") as mock_mem0:
            mock_mem0.search.return_value = [{"memory": "Alice is a software engineer"}]
            with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}):
                with patch("openai.AsyncOpenAI") as mock_openai:
                    with patch("anthropic.AsyncAnthropic") as mock_anthropic_cls:
                        mock_client = MagicMock()
                        mock_client.messages.create = AsyncMock(return_value=mock_response)
                        mock_anthropic_cls.return_value = mock_client
                        from memory import query_memory
                        result = await query_memory("who is Alice?")
                        assert result["answer"] == "Alice is a software engineer."
                        mock_openai.assert_not_called()
                        mock_anthropic_cls.assert_called_once()

@pytest.mark.asyncio
async def test_query_memory_silent_when_no_anthropic_key_and_no_openai_key():
    with patch("memory.MEM0") as mock_mem0:
        mock_mem0.search.return_value = [{"memory": "some fact"}]
        with patch("memory.GRAPHITI", None):
            env = {k: v for k, v in os.environ.items()
                   if k not in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY")}
            with patch.dict(os.environ, env, clear=True):
                from memory import query_memory
                result = await query_memory("test?")
                assert result["answer"] == "some fact"

@pytest.mark.asyncio
async def test_reflect_memory_uses_anthropic():
    mock_response = MagicMock()
    mock_response.content = [MagicMock(text='{"observations": [], "patterns": ["user codes a lot"], "relationships": [], "summary": "User was coding"}')]
    with patch("memory.MEM0", None):
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}):
            with patch("openai.AsyncOpenAI") as mock_openai:
                with patch("anthropic.AsyncAnthropic") as mock_anthropic_cls:
                    mock_client = MagicMock()
                    mock_client.messages.create = AsyncMock(return_value=mock_response)
                    mock_anthropic_cls.return_value = mock_client
                    from memory import reflect_memory
                    result = await reflect_memory([SAMPLE_SNAPSHOT])
                    assert result["summary"] == "User was coding"
                    mock_openai.assert_not_called()
                    mock_anthropic_cls.assert_called_once()

@pytest.mark.asyncio
async def test_reflect_memory_handles_fenced_json():
    """Ensure markdown-fenced JSON from Opus is handled correctly."""
    fenced = '```json\n{"observations": [], "patterns": [], "relationships": [], "summary": "ok"}\n```'
    mock_response = MagicMock()
    mock_response.content = [MagicMock(text=fenced)]
    with patch("memory.MEM0", None):
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}):
            with patch("anthropic.AsyncAnthropic") as mock_cls:
                mock_client = MagicMock()
                mock_client.messages.create = AsyncMock(return_value=mock_response)
                mock_cls.return_value = mock_client
                from memory import reflect_memory
                result = await reflect_memory([SAMPLE_SNAPSHOT])
                assert result["summary"] == "ok"
