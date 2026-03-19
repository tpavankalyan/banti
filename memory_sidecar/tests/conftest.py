# memory_sidecar/tests/conftest.py
import pytest
from main import create_app

@pytest.fixture
def app():
    return create_app(testing=True)
