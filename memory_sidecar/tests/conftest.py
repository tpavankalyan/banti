# memory_sidecar/tests/conftest.py
import pytest
from main import create_app

@pytest.fixture
def app():
    # testing=True suppresses heavy ML model init — do not remove
    return create_app(testing=True)
