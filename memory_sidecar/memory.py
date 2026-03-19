# memory_sidecar/memory.py
import asyncio
import os
import re
import uuid
import json
import anthropic
from datetime import datetime
from typing import Optional
from collections import deque

def extract_sentences(buffer: str, min_words: int = 4) -> tuple[list[str], str]:
    """Split accumulated LLM token buffer into emittable sentences.

    Returns (emittable_sentences, remaining_buffer).
    A sentence is emitted when it ends with .!? and has >= min_words words.
    Short sentences (< min_words) stay in the buffer and merge with subsequent text.
    """
    sentences = []
    last_emitted = 0

    for match in re.finditer(r'[.!?](?=[ \n]|$)', buffer):
        end = match.end()
        segment = buffer[last_emitted:end].strip()
        if segment and len(segment.split()) >= min_words:
            sentences.append(segment)
            last_emitted = end
            # skip leading whitespace before next segment
            while last_emitted < len(buffer) and buffer[last_emitted] in ' \n':
                last_emitted += 1

    remaining = buffer[last_emitted:]
    return sentences, remaining


from openai import AsyncOpenAI

REFLEX_SYSTEM_PROMPT = """\
You are banti, an ambient AI assistant watching over the user's Mac.
Speak in short, natural sentences — like a thoughtful friend nearby.
React only to what's genuinely happening right now. 1-2 sentences max.
Respond with plain prose only. No JSON. No markdown. No preamble.
If there is truly nothing worth saying, respond with exactly: [silent]"""


def _sse(event: dict) -> str:
    return f"data: {json.dumps(event)}\n\n"


async def _reflex_stream(req):
    """Async generator: yields SSE strings for the reflex track."""
    cerebras_key = os.environ.get("CEREBRAS_API_KEY")
    if not cerebras_key:
        yield _sse({"type": "error"})
        return

    client = AsyncOpenAI(base_url="https://api.cerebras.ai/v1", api_key=cerebras_key)
    user_msg = f"Snapshot:\n{req.snapshot_json}\n\nRecent speech:\n" + "\n".join(req.recent_speech)

    buffer = ""
    try:
        async with asyncio.timeout(8):
            stream = await client.chat.completions.create(
                model="gpt-oss-120b",
                messages=[
                    {"role": "system", "content": REFLEX_SYSTEM_PROMPT},
                    {"role": "user", "content": user_msg},
                ],
                stream=True,
                max_tokens=120,
            )
            async for chunk in stream:
                delta = chunk.choices[0].delta.content or ""
                buffer += delta
                sentences, buffer = extract_sentences(buffer)
                for s in sentences:
                    yield _sse({"type": "sentence", "text": s})
    except Exception:
        yield _sse({"type": "error"})
        return

    # Flush remaining buffer
    remaining = buffer.strip()
    if remaining == "[silent]":
        yield _sse({"type": "silent"})
    elif remaining:
        yield _sse({"type": "sentence", "text": remaining})


REASONING_SYSTEM_PROMPT = """\
You are banti. A quick reflex response was just given. Now add depth, memory,
or context only if you have something genuinely useful to say. 1-3 sentences.
Plain prose only — no JSON, no preamble.
If you have nothing meaningful to add, respond with exactly: [silent]"""


async def _reasoning_stream(req):
    """Async generator: yields SSE strings for the reasoning track (Opus 4.6 + memory)."""
    anthropic_key = os.environ.get("ANTHROPIC_API_KEY")
    if not anthropic_key:
        yield _sse({"type": "error"})
        return

    # Fetch Graphiti + mem0 in parallel
    context_parts = []
    if GRAPHITI is not None or MEM0 is not None:
        async def _fetch_graphiti():
            if GRAPHITI is None:
                return
            try:
                edges = await GRAPHITI.search("recent events and who is present", num_results=3)
                facts = [e.fact for e in edges if e.fact]
                if facts:
                    context_parts.append("Temporal memory:\n" + "\n".join(f"  - {f}" for f in facts))
            except Exception as e:
                print(f"[warn] reasoning_stream: Graphiti failed: {e}")

        async def _fetch_mem0():
            if MEM0 is None:
                return
            try:
                snap_dict = json.loads(req.snapshot_json) if req.snapshot_json != "{}" else {}
                person = snap_dict.get("person")
                if person and person.get("name") and person.get("id"):
                    user_id = f"person_{person['id']}"
                    hits = MEM0.search(person["name"], user_id=user_id, limit=3)
                    facts = [h["memory"] for h in hits if "memory" in h]
                    if facts:
                        context_parts.append(
                            f"What I know about {person['name']}:\n" +
                            "\n".join(f"  - {f}" for f in facts)
                        )
            except Exception as e:
                print(f"[warn] reasoning_stream: mem0 failed: {e}")

        await asyncio.gather(_fetch_graphiti(), _fetch_mem0())

    snapshot_summary = "\n\n".join(context_parts) if context_parts else "(no memory context)"
    user_msg = (
        f"Memory context:\n{snapshot_summary}\n\n"
        f"Current snapshot:\n{req.snapshot_json}\n\n"
        f"Recent speech:\n" + "\n".join(req.recent_speech)
    )

    buffer = ""
    try:
        async_client = anthropic.AsyncAnthropic(api_key=anthropic_key)
        async with asyncio.timeout(20):
            async with async_client.messages.stream(
                model="claude-opus-4-6",
                max_tokens=200,
                system=REASONING_SYSTEM_PROMPT,
                messages=[{"role": "user", "content": user_msg}],
            ) as stream:
                async for text in stream.text_stream:
                    buffer += text
                    sentences, buffer = extract_sentences(buffer)
                    for s in sentences:
                        yield _sse({"type": "sentence", "text": s})
    except Exception as e:
        print(f"[warn] reasoning_stream: failed: {e}")
        yield _sse({"type": "error"})
        return

    remaining = buffer.strip()
    if remaining == "[silent]":
        yield _sse({"type": "silent"})
    elif remaining:
        yield _sse({"type": "sentence", "text": remaining})


async def brain_stream_generate(req):
    """Top-level SSE generator — routes to reflex or reasoning track."""
    if req.track == "reflex":
        async for event in _reflex_stream(req):
            yield event
    else:
        async for event in _reasoning_stream(req):
            yield event
    yield _sse({"type": "done"})


GRAPHITI = None
MEM0 = None

_episode_buffer: deque = deque(maxlen=100)
_last_snapshot_text: Optional[str] = None

async def init_memory() -> None:
    global GRAPHITI, MEM0

    neo4j_uri  = os.environ.get("NEO4J_URI")
    neo4j_user = os.environ.get("NEO4J_USER", "neo4j")
    neo4j_pass = os.environ.get("NEO4J_PASSWORD")

    if neo4j_uri and neo4j_pass:
        try:
            from graphiti_core import Graphiti
            GRAPHITI = Graphiti(neo4j_uri, neo4j_user, neo4j_pass)
            await GRAPHITI.build_indices_and_constraints()
        except Exception as e:
            print(f"[warn] Graphiti init failed: {e} — temporal memory disabled")
            GRAPHITI = None
    else:
        print("[warn] NEO4J_URI/NEO4J_PASSWORD missing — temporal memory disabled")

    openai_key = os.environ.get("OPENAI_API_KEY")
    if openai_key:
        try:
            from mem0 import Memory
            MEM0 = Memory()
        except Exception as e:
            print(f"[warn] mem0 init failed: {e} — semantic memory disabled")
            MEM0 = None
    else:
        print("[warn] OPENAI_API_KEY missing — semantic memory disabled")


def snapshot_to_episode(snapshot: dict, wall_ts: datetime) -> Optional[str]:
    """Transform raw snapshotJSON dict into human-readable episode text."""
    parts = []

    if sp := snapshot.get("speech"):
        name = sp.get("resolvedName") or "unknown speaker"
        transcript = sp.get("transcript", "")
        if transcript.strip():
            parts.append(f'{name} said: "{transcript}"')

    if p := snapshot.get("person"):
        name = p.get("name") or "an unknown person"
        parts.append(f"{name} was visible on camera")

    if a := snapshot.get("activity"):
        desc = a.get("description", "")
        if desc:
            parts.append(f"Activity: {desc}")

    if sc := snapshot.get("screen"):
        interp = sc.get("interpretation", "")
        if interp:
            parts.append(f"Screen: {interp}")

    if em := snapshot.get("voiceEmotion"):
        emotions = em.get("emotions", [])
        if emotions:
            top = sorted(emotions, key=lambda e: e.get("score", 0), reverse=True)[:2]
            labels = ", ".join(e["label"] for e in top)
            parts.append(f"Vocal emotion: {labels}")

    return ". ".join(parts) if parts else None


async def ingest_snapshot(snapshot_json: str, wall_ts: datetime) -> dict:
    global _last_snapshot_text

    if snapshot_json == "{}" or not snapshot_json.strip():
        return {"skipped": True, "reason": "empty"}

    try:
        snapshot = json.loads(snapshot_json)
    except json.JSONDecodeError:
        return {"skipped": True, "reason": "invalid json"}

    episode_text = snapshot_to_episode(snapshot, wall_ts)
    if not episode_text:
        return {"skipped": True, "reason": "no meaningful content"}

    if episode_text == _last_snapshot_text:
        return {"skipped": True, "reason": "duplicate"}

    _last_snapshot_text = episode_text

    if GRAPHITI is not None:
        try:
            await GRAPHITI.add_episode(
                name=f"snapshot_{uuid.uuid4().hex[:8]}",
                episode_body=episode_text,
                source_description="banti ambient perception",
                reference_time=wall_ts,
            )
        except Exception as e:
            print(f"[warn] Graphiti ingest failed: {e} — buffering")
            _episode_buffer.append((episode_text, wall_ts))

    if MEM0 is not None:
        try:
            MEM0.add(episode_text, user_id="banti_self")
        except Exception as e:
            print(f"[warn] mem0 ingest failed: {e}")

        person = snapshot.get("person")
        if person and person.get("id") and person.get("name"):
            mem0_user_id = f"person_{person['id']}"
            try:
                MEM0.add(episode_text, user_id=mem0_user_id)
            except Exception as e:
                print(f"[warn] mem0 person ingest failed for {mem0_user_id}: {e}")

    return {"skipped": False, "episode": episode_text}


async def query_memory(q: str, context_json: Optional[str] = None) -> dict:
    results = []

    if GRAPHITI is not None:
        try:
            edges = await GRAPHITI.search(q, num_results=5)
            results.extend(edge.fact for edge in edges if edge.fact)
        except Exception as e:
            print(f"[warn] Graphiti search failed: {e}")

    if MEM0 is not None:
        try:
            hits = MEM0.search(q, user_id="banti_self", limit=5)
            results.extend(h["memory"] for h in hits if "memory" in h)
        except Exception as e:
            print(f"[warn] mem0 search failed: {e}")

    if not results:
        return {"answer": "", "sources": []}

    anthropic_key = os.environ.get("ANTHROPIC_API_KEY")
    if not anthropic_key:
        return {"answer": ". ".join(results[:3]), "sources": results}

    try:
        client = anthropic.AsyncAnthropic(api_key=anthropic_key)
        facts = "\n".join(f"- {r}" for r in results)
        system_content = "You are banti's memory. Answer the user's question using only the provided facts. Be concise."
        if context_json:
            system_content += f" Current context: {context_json}"
        response = await client.messages.create(
            model="claude-opus-4-6",
            max_tokens=200,
            system=system_content,
            messages=[{"role": "user", "content": f"Facts:\n{facts}\n\nQuestion: {q}"}],
        )
        answer = response.content[0].text or ""
    except Exception as e:
        print(f"[warn] Opus query fusion failed: {e}")
        answer = ". ".join(results[:3])

    return {"answer": answer, "sources": results}


async def reflect_memory(snapshots: list[str]) -> dict:
    if not snapshots:
        return {"summary": ""}

    anthropic_key = os.environ.get("ANTHROPIC_API_KEY")
    if not anthropic_key:
        return {"summary": ""}

    episodes = []
    now = datetime.utcnow()
    for snap in snapshots:
        try:
            ep = snapshot_to_episode(json.loads(snap), now)
            if ep:
                episodes.append(ep)
        except Exception:
            continue

    if not episodes:
        return {"summary": "No meaningful episodes"}

    context = "\n".join(f"- {ep}" for ep in episodes[-50:])
    prompt = f"""You are banti's self-model. Analyze recent observations and respond with JSON.
Return ONLY valid JSON with no markdown fences:
{{
  "observations": ["time-anchored facts"],
  "patterns": ["recurring signals"],
  "relationships": [{{"person": "Name", "facts": ["..."]}}],
  "summary": "one sentence"
}}

Recent observations:
{context}"""

    try:
        client = anthropic.AsyncAnthropic(api_key=anthropic_key)
        resp = await client.messages.create(
            model="claude-opus-4-6",
            max_tokens=500,
            messages=[{"role": "user", "content": prompt}],
        )
        raw = resp.content[0].text or "{}"
        raw = re.sub(r'^```[a-z]*\n?|\n?```$', '', raw.strip())
        result = json.loads(raw)
    except Exception as e:
        print(f"[warn] Opus reflection failed: {e}")
        return {"summary": "reflection failed"}

    self_json_path = os.path.expanduser(
        "~/Library/Application Support/banti/self.json"
    )
    os.makedirs(os.path.dirname(self_json_path), exist_ok=True)
    existing = {}
    if os.path.exists(self_json_path):
        try:
            with open(self_json_path) as f:
                existing = json.load(f)
        except Exception:
            pass

    existing["last_reflection"] = now.isoformat() + "Z"
    if "patterns" in result:
        existing["recent_patterns"] = result["patterns"]
    if "observations" in result:
        existing["recent_observations"] = result["observations"]

    with open(self_json_path, "w") as f:
        json.dump(existing, f, indent=2)

    if MEM0 is not None:
        for pattern in result.get("patterns", []):
            try:
                MEM0.add(pattern, user_id="banti_self")
            except Exception:
                pass

    return {"summary": result.get("summary", "reflection complete")}


BRAIN_SYSTEM_PROMPT = """You are banti, an ambient personal AI assistant running on the user's Mac.
You passively observe via camera, microphone, and screen. You have persistent
memory of people, events, and patterns.

Your job right now: decide whether to speak or stay silent.

Speak when you have something genuinely useful, curious, or warm to say.
Think like a thoughtful friend who notices things — not a notification.
Ask questions when you're curious, like a human would.
Offer help when you notice the user might need it.
Comment on something interesting you observed.

Stay silent when:
- The user is clearly focused and shouldn't be interrupted
- You spoke recently and nothing significant has changed
- You have nothing meaningful to add

Return ONLY valid JSON with no markdown fences:
{"action": "speak"|"silent", "text": "<what to say, 1-2 sentences max, or null if silent>", "reason": "<brief internal note>"}"""


async def brain_decide(req) -> "ProactiveDecisionResponse":
    """Decide whether banti should speak. Returns ProactiveDecisionResponse."""
    from models import ProactiveDecisionResponse

    anthropic_key = os.environ.get("ANTHROPIC_API_KEY")
    if not anthropic_key:
        return ProactiveDecisionResponse(action="silent", reason="ANTHROPIC_API_KEY missing")

    # --- assemble context ---
    context_parts = []

    # snapshot signals
    try:
        snap = json.loads(req.snapshot_json)
        if snap:
            context_parts.append(f"Current perception: {json.dumps(snap, indent=None)}")
    except Exception:
        pass

    # recent speech
    if req.recent_speech:
        lines = "\n".join(f"  - {s}" for s in req.recent_speech)
        context_parts.append(f"Recent speech:\n{lines}")

    # temporal memory (Graphiti)
    if GRAPHITI is not None:
        try:
            query_hint = "recent events and who is present"
            edges = await GRAPHITI.search(query_hint, num_results=3)
            facts = [e.fact for e in edges if e.fact]
            if facts:
                context_parts.append("Temporal memory:\n" + "\n".join(f"  - {f}" for f in facts))
        except Exception as e:
            print(f"[warn] brain_decide: Graphiti search failed: {e}")

    # semantic memory (mem0) for named person
    if MEM0 is not None:
        try:
            snap_dict = json.loads(req.snapshot_json) if req.snapshot_json != "{}" else {}
            person = snap_dict.get("person")
            if person and person.get("name") and person.get("id"):
                user_id = f"person_{person['id']}"
                hits = MEM0.search(person["name"], user_id=user_id, limit=3)
                facts = [h["memory"] for h in hits if "memory" in h]
                if facts:
                    context_parts.append(f"What I know about {person['name']}:\n" +
                                         "\n".join(f"  - {f}" for f in facts))
        except Exception as e:
            print(f"[warn] brain_decide: mem0 search failed: {e}")

    # self model
    self_json_path = os.path.expanduser("~/Library/Application Support/banti/self.json")
    if os.path.exists(self_json_path):
        try:
            with open(self_json_path) as f:
                self_data = json.load(f)
            if self_data.get("recent_patterns"):
                patterns = self_data["recent_patterns"][:3]
                context_parts.append("My recent patterns:\n" + "\n".join(f"  - {p}" for p in patterns))
        except Exception:
            pass

    # last spoke context
    if req.last_spoke_seconds_ago < 9999:
        context_parts.append(
            f"I last spoke {req.last_spoke_seconds_ago:.0f}s ago"
            + (f': "{req.last_spoke_text}"' if req.last_spoke_text else "")
        )

    user_content = "\n\n".join(context_parts) if context_parts else "No context available yet."

    try:
        client = anthropic.AsyncAnthropic(api_key=anthropic_key)
        response = await client.messages.create(
            model="claude-opus-4-6",
            max_tokens=150,
            system=BRAIN_SYSTEM_PROMPT,
            messages=[{"role": "user", "content": user_content}],
        )
        raw = response.content[0].text
        raw = re.sub(r'^```[a-z]*\n?|\n?```$', '', raw.strip())
        data = json.loads(raw)
        return ProactiveDecisionResponse(
            action=data.get("action", "silent"),
            text=data.get("text") or None,
            reason=data.get("reason", ""),
        )
    except Exception as e:
        print(f"[warn] brain_decide: Opus call failed: {e}")
        return ProactiveDecisionResponse(action="silent", reason=f"llm error: {e}")
