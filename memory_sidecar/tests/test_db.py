# memory_sidecar/tests/test_db.py
import pytest
import os
from db import init_db, create_person, get_person_by_id, update_person_name, get_all_persons

@pytest.fixture
def test_db(tmp_path):
    db_path = str(tmp_path / "test.db")
    init_db(db_path)
    return db_path

def test_init_db_creates_table(test_db):
    import sqlite3
    conn = sqlite3.connect(test_db)
    cursor = conn.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='persons'")
    assert cursor.fetchone() is not None
    conn.close()

def test_create_person_returns_id(test_db):
    person_id = create_person(test_db, display_name=None, face_embedding=None, voice_embedding=None)
    assert person_id.startswith("p_")

def test_create_person_assigns_mem0_user_id(test_db):
    person_id = create_person(test_db, display_name="Alice", face_embedding=None, voice_embedding=None)
    person = get_person_by_id(test_db, person_id)
    assert person["mem0_user_id"] == f"person_{person_id}"

def test_get_person_by_id_returns_none_for_missing(test_db):
    result = get_person_by_id(test_db, "p_9999")
    assert result is None

def test_update_person_name(test_db):
    person_id = create_person(test_db, display_name=None, face_embedding=None, voice_embedding=None)
    update_person_name(test_db, person_id, "Bob")
    person = get_person_by_id(test_db, person_id)
    assert person["display_name"] == "Bob"

def test_get_all_persons_empty_initially(test_db):
    assert get_all_persons(test_db) == []
