"""Shared pytest fixtures and autouse hooks for the daemon test suite."""
import pytest


@pytest.fixture(autouse=True)
def reset_config_path_cache():
    """Reset the module-level config path cache before every test.

    daemon.config.get_config_path() caches the resolved path in a module-level
    variable (_config_path).  Without resetting it, tests that set SOL_CONFIG
    via monkeypatch run after an earlier test has already locked in a different
    path, causing the wrong config file (or a missing file) to be used.
    """
    import daemon.config as cfg_module
    cfg_module._config_path = None
    yield
    cfg_module._config_path = None
