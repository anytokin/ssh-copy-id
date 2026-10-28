"""The package version, also read by Hatch when building distributions."""

__version__ = "0.1.18"


def get_version() -> str:
    """Return the version without requiring repository files at runtime."""
    return __version__
