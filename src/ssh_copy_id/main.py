import argparse
import posixpath
import re
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Optional

from ssh_copy_id.version import get_version


def parse_user_host(user_at_host: Optional[str]) -> str:
    """Accept a hostname or user@host and prompt for missing parts."""
    user = ""
    host = ""
    if user_at_host:
        if "@" in user_at_host:
            user, host = user_at_host.split("@", 1)
        else:
            host = user_at_host

    user = user.strip()
    host = host.strip()
    if not user:
        user = input("Enter SSH username: ").strip()
    if not host:
        host = input("Enter SSH host (IP or hostname): ").strip()

    for name, value in (("username", user), ("host", host)):
        if not value or any(char.isspace() for char in value) or "\0" in value or "@" in value:
            raise ValueError("SSH {} must be nonempty and contain no whitespace or @.".format(name))
    return "{}@{}".format(user, host)


def _quote_remote_path(path: str) -> str:
    """Quote for the remote POSIX shell while expanding the remote home."""
    if path == "~":
        return '"$HOME"'
    if path.startswith("~/"):
        return '"$HOME"/' + shlex.quote(path[2:])
    # Relative names beginning with '-' must not become chmod/mkdir options.
    if path.startswith("-"):
        path = "./" + path
    return shlex.quote(path)


def _build_remote_command(target_path: str) -> str:
    if (
        not target_path.strip()
        or any(char in target_path for char in ("\0", "\r", "\n"))
        or target_path.endswith("/")
        or target_path in (".", "..", "~")
    ):
        raise ValueError("The remote target must be a file path.")

    # The destination belongs to the remote machine, even when we run on Windows.
    parent_path = posixpath.dirname(target_path) or "."
    parent = _quote_remote_path(parent_path)
    target = _quote_remote_path(target_path)
    commands = ["umask 077", "mkdir -p {}".format(parent)]
    if parent_path in ("~/.ssh", ".ssh"):
        commands.append("chmod 700 {}".format(parent))
    # authorized_keys may already contain a key without a terminating newline.
    commands.append("if [ -s {0} ]; then printf '\\n' >> {0}; fi".format(target))
    commands.extend(("cat >> {}".format(target), "chmod 600 {}".format(target)))
    return " && ".join(commands)


def _fail(message: str) -> None:
    print("[!] {}".format(message), file=sys.stderr)
    raise SystemExit(1)


def ssh_copy_id(**kwargs) -> None:
    pubkey_path = Path(kwargs.get("identity_file") or Path.home() / ".ssh" / "id_rsa.pub").expanduser()
    try:
        key = pubkey_path.read_text(encoding="utf-8-sig").strip()
    except FileNotFoundError:
        _fail("Public key not found: {}. Generate one with ssh-keygen.".format(pubkey_path))
    except (OSError, UnicodeError) as error:
        _fail("Unable to read public key {}: {}".format(pubkey_path, error))

    if not key:
        _fail("Public key file is empty: {}".format(pubkey_path))
    if re.search(r"^-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----", key, re.MULTILINE):
        _fail("The identity file contains a private key. Select its .pub file instead.")
    if "\0" in key:
        _fail("The public key file contains a NUL character.")

    if kwargs.get("n", False):
        print(key)
        return

    try:
        user_at_host = parse_user_host(kwargs.get("user_at_host"))
        remote_cmd = _build_remote_command(kwargs.get("t", "~/.ssh/authorized_keys"))
    except ValueError as error:
        _fail(str(error))
    except EOFError:
        _fail("SSH username and host are required. Specify user@host when input is unavailable.")
    except KeyboardInterrupt:
        print("\n[!] Cancelled.", file=sys.stderr)
        raise SystemExit(130)

    print("[+] Copying key to {} ...".format(user_at_host))
    ssh_command = ["ssh", "-p", str(kwargs.get("port", 22)), "--", user_at_host, remote_cmd]
    if kwargs.get("x", False):
        print("Running: {}".format(shlex.join(ssh_command)))

    try:
        result = subprocess.run(
            ssh_command,
            input=(key + "\n").encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError:
        _fail("SSH client not found. Install OpenSSH and ensure ssh is on PATH.")
    except OSError as error:
        _fail("Unable to start SSH: {}".format(error))
    except KeyboardInterrupt:
        print("\n[!] Cancelled.", file=sys.stderr)
        raise SystemExit(130)

    if result.returncode == 0:
        print("[+] Public key added successfully.")
    else:
        print("[!] SSH command failed.", file=sys.stderr)
        for output in (result.stdout, result.stderr):
            if output:
                output = output.decode("utf-8", errors="replace")
                print(output, end="" if output.endswith("\n") else "\n", file=sys.stderr)
        raise SystemExit(result.returncode)


def _parse_port(value: str) -> int:
    try:
        port = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("SSH port must be an integer between 1 and 65535.")
    if not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError("SSH port must be between 1 and 65535.")
    return port


def main():
    # Windows' legacy console encoding cannot represent every key comment or
    # decoded SSH diagnostic. Redirected CLI output should be UTF-8 as well.
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            try:
                reconfigure(encoding="utf-8", errors="backslashreplace")
            except (OSError, ValueError):
                pass

    parser = argparse.ArgumentParser(description="Alternative for Linux's ssh-copy-id")
    parser.add_argument(
        "user_at_host",
        nargs="?",
        help="REMOTE_HOST or REMOTE_USER@REMOTE_HOST"
    )
    parser.add_argument(
        "-p", "--port",
        type=_parse_port,
        default=22,
        help="SSH port (default: 22)",
    )
    parser.add_argument(
        "-i", "--identity-file",
        default=str(Path.home() / ".ssh" / "id_rsa.pub"),
        help="Path to public key file (default: ~/.ssh/id_rsa.pub)"
    )
    parser.add_argument(
        "-x",
        action="store_true",
        help="Debugging the ssh-copy-id script itself"
    )

    parser.add_argument(
        "-n",
        action="store_true",
        help="""Do a dry-run. Instead of installing keys on the remote
               system simply prints the key(s) that would have been
               installed""",
    )
    parser.add_argument(
        "-t",
        type=str,
        default="~/.ssh/authorized_keys",
        help="""The path on the target system where the keys should be
               added (defaults to "~/.ssh/authorized_keys")"""
    )
    parser.add_argument(
        "-v",
        action='store_true',
        help="""Return ssh-copy-id version"""
    )

    args = parser.parse_args()
    if args.v:
        print(get_version())
        return
    ssh_copy_id(**vars(args))


if __name__ == "__main__":
    main()
