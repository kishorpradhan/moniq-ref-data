from __future__ import annotations

import os


def get_aws_profile(default: str = "default") -> str:
    return os.getenv("AWS_PROFILE", default)
