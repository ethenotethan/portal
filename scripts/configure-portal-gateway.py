#!/usr/bin/env python3
"""Securely configure Portal's local Hermes API server and handoff.

Secrets are generated or read in-process and never accepted through argv,
printed, or embedded in service definitions.
"""

import argparse
import json
import os
from pathlib import Path
import secrets
import stat
import tempfile
from typing import Dict, Iterable, List, Tuple


MANAGED_KEYS = ("API_SERVER_ENABLED", "API_SERVER_HOST", "API_SERVER_PORT", "API_SERVER_KEY")


def validate_existing_file(path: Path, require_private: bool) -> None:
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise ValueError("refusing a non-regular configuration file")
    if info.st_uid != os.getuid():
        raise ValueError("refusing a configuration file owned by another user")
    if info.st_nlink != 1:
        raise ValueError("refusing a multiply-linked configuration file")
    if require_private and stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError("configuration file permissions are not private")


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    parent_info = path.parent.lstat()
    if stat.S_ISLNK(parent_info.st_mode) or not stat.S_ISDIR(parent_info.st_mode):
        raise ValueError("refusing an unsafe configuration directory")
    if parent_info.st_uid != os.getuid():
        raise ValueError("refusing a configuration directory owned by another user")

    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            descriptor = -1
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
        os.chmod(path, 0o600)
        directory_descriptor = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


def parse_environment(lines: Iterable[str]) -> Dict[str, str]:
    values: Dict[str, str] = {}
    for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        values[name.strip()] = value
    return values


def valid_key(value: str) -> bool:
    return len(value) == 64 and all(character in "0123456789abcdef" for character in value)


def render_environment(existing_lines: List[str], updates: Dict[str, str]) -> str:
    rendered: List[str] = []
    replaced = set()
    for raw_line in existing_lines:
        stripped = raw_line.strip()
        if stripped and not stripped.startswith("#") and "=" in stripped:
            name = stripped.split("=", 1)[0].strip()
            if name in updates:
                if name not in replaced:
                    rendered.append(f"{name}={updates[name]}\n")
                    replaced.add(name)
                continue
        rendered.append(raw_line if raw_line.endswith("\n") else raw_line + "\n")
    for name in MANAGED_KEYS:
        if name not in replaced:
            rendered.append(f"{name}={updates[name]}\n")
    return "".join(rendered)


def configure(env_file: Path) -> Dict[str, object]:
    existing_lines: List[str] = []
    if env_file.exists() or env_file.is_symlink():
        validate_existing_file(env_file, require_private=False)
        existing_lines = env_file.read_text(encoding="utf-8").splitlines(keepends=True)
    existing = parse_environment(existing_lines)
    existing_key = existing.get("API_SERVER_KEY", "")
    key = existing_key if valid_key(existing_key) else secrets.token_hex(32)
    updates = {
        "API_SERVER_ENABLED": "true",
        "API_SERVER_HOST": "127.0.0.1",
        "API_SERVER_PORT": existing.get("API_SERVER_PORT", "8642"),
        "API_SERVER_KEY": key,
    }
    try:
        port = int(updates["API_SERVER_PORT"])
    except ValueError as error:
        raise ValueError("API server port is invalid") from error
    if port < 1 or port > 65535:
        raise ValueError("API server port is invalid")
    atomic_write(env_file, render_environment(existing_lines, updates))
    return {"configured": True, "reusedKey": key == existing_key}


def write_handoff(env_file: Path, handoff_file: Path) -> Dict[str, object]:
    validate_existing_file(env_file, require_private=True)
    environment = parse_environment(env_file.read_text(encoding="utf-8").splitlines())
    key = environment.get("API_SERVER_KEY", "")
    if not valid_key(key):
        raise ValueError("configured API server key is missing or weak")
    if environment.get("API_SERVER_HOST", "127.0.0.1") != "127.0.0.1":
        raise ValueError("only a loopback API server can be handed to Portal")
    try:
        port = int(environment.get("API_SERVER_PORT", "8642"))
    except ValueError as error:
        raise ValueError("configured API server port is invalid") from error
    if port < 1 or port > 65535:
        raise ValueError("configured API server port is invalid")
    payload = json.dumps(
        {
            "schemaVersion": 1,
            "gatewayURL": f"ws://127.0.0.1:{port}/v1/ws",
            "apiKey": key,
        },
        separators=(",", ":"),
    ) + "\n"
    if handoff_file.exists() or handoff_file.is_symlink():
        validate_existing_file(handoff_file, require_private=False)
    atomic_write(handoff_file, payload)
    return {"handoffWritten": True}


def parser() -> argparse.ArgumentParser:
    argument_parser = argparse.ArgumentParser()
    subparsers = argument_parser.add_subparsers(dest="command", required=True)
    configure_parser = subparsers.add_parser("configure")
    configure_parser.add_argument("--env-file", type=Path, required=True)
    handoff_parser = subparsers.add_parser("handoff")
    handoff_parser.add_argument("--env-file", type=Path, required=True)
    handoff_parser.add_argument("--handoff-file", type=Path, required=True)
    return argument_parser


def main() -> int:
    arguments = parser().parse_args()
    try:
        if arguments.command == "configure":
            result = configure(arguments.env_file)
        else:
            result = write_handoff(arguments.env_file, arguments.handoff_file)
    except (OSError, ValueError, UnicodeError, json.JSONDecodeError) as error:
        print(f"portal gateway configuration failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    import sys

    raise SystemExit(main())
