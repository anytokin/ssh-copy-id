import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from ssh_copy_id.main import _build_remote_command, main, parse_user_host, ssh_copy_id


class DestinationTests(unittest.TestCase):
    def test_hostname_prompts_for_username(self):
        with patch("builtins.input", return_value="alice") as prompt:
            self.assertEqual(parse_user_host("server.example.org"), "alice@server.example.org")
        prompt.assert_called_once_with("Enter SSH username: ")

    def test_ipv4_and_ipv6_are_hosts(self):
        for host in ("192.0.2.1", "2001:db8::1"):
            with self.subTest(host=host), patch("builtins.input", return_value="alice"):
                self.assertEqual(parse_user_host(host), "alice@" + host)

    def test_complete_destination_needs_no_input(self):
        with patch("builtins.input", side_effect=AssertionError("Unexpected prompt")):
            self.assertEqual(parse_user_host(" alice@server.example.org "), "alice@server.example.org")

    def test_missing_parts_are_prompted(self):
        cases = ((None, ["alice", "server"], "alice@server"),
                 ("@server", ["alice"], "alice@server"),
                 ("alice@", ["server"], "alice@server"))
        for destination, answers, expected in cases:
            with self.subTest(destination=destination), patch("builtins.input", side_effect=answers):
                self.assertEqual(parse_user_host(destination), expected)

    def test_empty_and_malformed_parts_are_rejected(self):
        for destination in ("alice@bad host", "alice@host@other", "alice\0@host"):
            with self.subTest(destination=destination), self.assertRaises(ValueError):
                parse_user_host(destination)
        with patch("builtins.input", return_value=""), self.assertRaises(ValueError):
            parse_user_host("@server")


class CopyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.key_path = Path(self.directory.name) / "id_ed25519.pub"
        self.key = "ssh-ed25519 AAAATEST alice@example.org"
        self.key_path.write_text(self.key + "\n", encoding="utf-8")
        self.options = dict(user_at_host="alice@server", identity_file=str(self.key_path), port=22)
        self.stdout = io.StringIO()
        self.stderr = io.StringIO()
        output = contextlib.ExitStack()
        self.addCleanup(output.close)
        output.enter_context(contextlib.redirect_stdout(self.stdout))
        output.enter_context(contextlib.redirect_stderr(self.stderr))

    def test_key_is_sent_via_stdin_and_destination_cannot_add_options(self):
        self.key = "ssh-ed25519 AAAATEST someone's $(touch SHOULD_NOT_EXIST) key"
        self.key_path.write_text(self.key, encoding="utf-8")
        self.options["user_at_host"] = "-malicious@server"
        with patch("ssh_copy_id.main.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, b"", b"")
            ssh_copy_id(**self.options)
        command = run.call_args.args[0]
        self.assertEqual(command[:5], ["ssh", "-p", "22", "--", "-malicious@server"])
        self.assertNotIn(self.key, command[-1])
        self.assertEqual(run.call_args.kwargs["input"], (self.key + "\n").encode("utf-8"))
        self.assertNotIn("text", run.call_args.kwargs)
        self.stdout.getvalue().encode("ascii")

    def test_dry_run_does_not_prompt_or_run_ssh(self):
        self.options["user_at_host"] = None
        with patch("builtins.input", side_effect=AssertionError("Unexpected prompt")), \
                patch("ssh_copy_id.main.subprocess.run") as run:
            ssh_copy_id(n=True, **self.options)
        self.assertEqual(self.stdout.getvalue(), self.key + "\n")
        run.assert_not_called()

    def test_utf8_bom_and_multiple_keys_are_preserved(self):
        keys = "ssh-ed25519 AAAATEST user's key Łódź 東京\nssh-rsa AAAATEST second key"
        self.key_path.write_text(keys, encoding="utf-8-sig")
        with patch("ssh_copy_id.main.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, b"", b"")
            ssh_copy_id(**self.options)
        self.assertEqual(run.call_args.kwargs["input"], (keys + "\n").encode("utf-8"))

    def test_subprocess_receives_utf8_without_windows_newline_translation(self):
        key = "ssh-ed25519 AAAATEST Łódź 東京"
        self.key_path.write_text(key, encoding="utf-8")
        real_run = subprocess.run
        received = []

        def echo_input(command, **options):
            result = real_run(
                [sys.executable, "-c", "import sys; sys.stdout.buffer.write(sys.stdin.buffer.read())"],
                **options
            )
            received.append(result.stdout)
            return subprocess.CompletedProcess(command, result.returncode, b"", result.stderr)

        with patch("ssh_copy_id.main.subprocess.run", side_effect=echo_input):
            ssh_copy_id(**self.options)
        self.assertEqual(received, [(key + "\n").encode("utf-8")])

    def test_cli_dry_run_prints_unicode_with_ascii_environment_encoding(self):
        key = "ssh-ed25519 AAAATEST Łódź 東京 🐍"
        self.key_path.write_text(key, encoding="utf-8")
        environment = dict(
            os.environ,
            PYTHONIOENCODING="ascii",
            PYTHONPATH=str(Path(__file__).resolve().parents[1] / "src"),
        )
        result = subprocess.run(
            [sys.executable, "-m", "ssh_copy_id.main", "-n", "-i", str(self.key_path)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))
        self.assertEqual(result.stdout.decode("utf-8").splitlines(), [key])

    def test_cli_ssh_diagnostics_print_safely_and_preserve_failure_status(self):
        stdout_buffer = io.BytesIO()
        stderr_buffer = io.BytesIO()
        stdout = io.TextIOWrapper(stdout_buffer, encoding="ascii")
        stderr = io.TextIOWrapper(stderr_buffer, encoding="ascii")
        self.addCleanup(stdout.close)
        self.addCleanup(stderr.close)
        with patch.object(sys, "stdout", stdout), patch.object(sys, "stderr", stderr), \
                patch.object(sys, "argv", ["ssh-copy-id", "-i", str(self.key_path), "alice@server"]), \
                patch("ssh_copy_id.main.subprocess.run") as run, self.assertRaises(SystemExit) as error:
            run.return_value = subprocess.CompletedProcess([], 255, b"", b"invalid byte: \xff")
            main()
        stdout.flush()
        stderr.flush()
        self.assertEqual(error.exception.code, 255)
        self.assertIn("invalid byte: �", stderr_buffer.getvalue().decode("utf-8"))

    def test_empty_private_and_binary_keys_are_rejected_before_ssh(self):
        for content in (" \n", "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret",
                        "-----BEGIN RSA PRIVATE KEY-----\nsecret", "bad\0key"):
            with self.subTest(content=content):
                self.key_path.write_text(content, encoding="utf-8")
                with patch("ssh_copy_id.main.subprocess.run") as run, self.assertRaises(SystemExit) as error:
                    ssh_copy_id(**self.options)
                self.assertEqual(error.exception.code, 1)
                run.assert_not_called()

    def test_missing_and_unreadable_keys_produce_useful_errors(self):
        for path in (self.key_path.with_name("missing.pub"), Path(self.directory.name)):
            with self.subTest(path=path):
                self.options["identity_file"] = str(path)
                with patch("builtins.input", side_effect=AssertionError("Unexpected prompt")), \
                        self.assertRaises(SystemExit) as error:
                    ssh_copy_id(**self.options)
                self.assertEqual(error.exception.code, 1)
        self.assertIn("Public key not found", self.stderr.getvalue())
        self.assertIn("Unable to read public key", self.stderr.getvalue())

    def test_missing_ssh_produces_useful_error(self):
        with patch("ssh_copy_id.main.subprocess.run", side_effect=FileNotFoundError), \
                self.assertRaises(SystemExit) as error:
            ssh_copy_id(**self.options)
        self.assertEqual(error.exception.code, 1)
        self.assertIn("SSH client not found", self.stderr.getvalue())

    def test_ssh_failure_preserves_status_and_diagnostics(self):
        with patch("ssh_copy_id.main.subprocess.run") as run, self.assertRaises(SystemExit) as error:
            run.return_value = subprocess.CompletedProcess([], 255, b"remote diagnostic", b"Permission denied")
            ssh_copy_id(**self.options)
        self.assertEqual(error.exception.code, 255)
        self.assertIn("Permission denied", self.stderr.getvalue())
        self.assertIn("remote diagnostic", self.stderr.getvalue())

    def test_unavailable_and_cancelled_input_are_reported_without_tracebacks(self):
        self.options["user_at_host"] = None
        for exception, status in ((EOFError, 1), (KeyboardInterrupt, 130)):
            with self.subTest(exception=exception), patch("builtins.input", side_effect=exception), \
                    self.assertRaises(SystemExit) as error:
                ssh_copy_id(**self.options)
            self.assertEqual(error.exception.code, status)

    def test_out_of_range_ports_are_rejected_before_connecting(self):
        for port in ("0", "65536", "-1", "not-a-port"):
            with self.subTest(port=port), patch.object(sys, "argv", ["ssh-copy-id", "-p", port]), \
                    patch("ssh_copy_id.main.subprocess.run") as run, self.assertRaises(SystemExit) as error:
                main()
            self.assertEqual(error.exception.code, 2)
            run.assert_not_called()


def _find_shell():
    for name in ("sh", "bash"):
        shell = shutil.which(name)
        if shell and not (os.name == "nt" and "system32" in shell.lower()):
            return shell
    if os.name == "nt":
        shell = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe"
        if shell.is_file():
            return str(shell)
    return None


POSIX_SHELL = _find_shell()


@unittest.skipUnless(POSIX_SHELL, "A POSIX shell is needed to exercise the remote command")
class RemoteCommandTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.home = Path(self.directory.name)
        self.environment = dict(os.environ, HOME=self.home.as_posix())

    def install_key(self, target, key):
        result = subprocess.run(
            [POSIX_SHELL, "-c", _build_remote_command(target)],
            input=key + "\n", text=True, encoding="utf-8",
            cwd=str(self.home), env=self.environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_default_target_uses_remote_home_and_posix_separators(self):
        key = "ssh-ed25519 AAAATEST default"
        self.install_key("~/.ssh/authorized_keys", key)
        target = self.home / ".ssh" / "authorized_keys"
        self.assertEqual(target.read_text(), key + "\n")
        if os.name != "nt":
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            self.assertEqual(target.parent.stat().st_mode & 0o777, 0o700)

    def test_custom_paths_and_key_comments_cannot_execute_shell_commands(self):
        key = "ssh-ed25519 AAAATEST user's $(touch KEY_INJECTION) `touch KEY_BACKTICK` key"
        relative_path = "nested dir/keys'$(touch TARGET_INJECTION); file"
        self.install_key("~/" + relative_path, key)
        self.assertEqual((self.home / relative_path).read_text(), key + "\n")
        for marker in ("KEY_INJECTION", "KEY_BACKTICK", "TARGET_INJECTION"):
            self.assertFalse((self.home / marker).exists())

    def test_home_level_target_does_not_create_literal_tilde_directory(self):
        self.install_key("~/authorized_keys", "ssh-ed25519 AAAATEST key")
        self.assertTrue((self.home / "authorized_keys").is_file())
        self.assertFalse((self.home / "~").exists())

    def test_existing_key_without_newline_is_not_corrupted(self):
        target = self.home / "authorized_keys"
        target.write_text("ssh-rsa AAAAOLD old-key", encoding="utf-8")
        self.install_key("authorized_keys", "ssh-ed25519 AAAANEW new-key")
        self.assertEqual(target.read_text().splitlines(),
                         ["ssh-rsa AAAAOLD old-key", "ssh-ed25519 AAAANEW new-key"])

    def test_relative_target_beginning_with_dash_is_not_an_option(self):
        self.install_key("-authorized_keys", "ssh-ed25519 AAAATEST key")
        self.assertTrue((self.home / "-authorized_keys").is_file())


if __name__ == "__main__":
    unittest.main()
