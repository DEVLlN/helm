#!/usr/bin/env python3
import argparse
import fcntl
import json
import os
import pty
import select
import selectors
import signal
import socket
import struct
import re
import subprocess
import sys
import termios
import time
import tty
from pathlib import Path

POST_SEND_EXIT_GRACE_SECONDS = 1.5
POST_INTERRUPT_EXIT_GRACE_SECONDS = 0.5
POST_INPUT_EXIT_GRACE_SECONDS = 0.1
TYPEWRITE_CHAR_DELAY_SECONDS = 0.002
LIVE_TAIL_MAX_CHARS = 20000
ANSI_ESCAPE_RE = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")
OSC_ESCAPE_RE = re.compile(r"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)")
CSI_CURSOR_LEFT_RE = re.compile(r"\x1B\[([0-9]*)D")
CSI_CURSOR_HORIZONTAL_ABSOLUTE_RE = re.compile(r"\x1B\[[0-9]*G")
CSI_ERASE_ENTIRE_LINE_RE = re.compile(r"\x1B\[2K")
INLINE_CONTROL_CHAR_RE = re.compile(r"[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]")
TEXTUAL_BRACKETED_PASTE_RE = re.compile(r"\^\[\[(?:200|201)~")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run a CLI runtime under helm shell relay control.")
    parser.add_argument("--registry-dir", required=True)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--wrapper", required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--thread-id")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command:
        parser.error("missing runtime command")
    return args


def sync_window_size(source_fd: int, target_fd: int) -> None:
    packed = fcntl.ioctl(source_fd, termios.TIOCGWINSZ, struct.pack("HHHH", 0, 0, 0, 0))
    fcntl.ioctl(target_fd, termios.TIOCSWINSZ, packed)


class LiveTailBuffer:
    def __init__(self, path: Path, max_chars: int = LIVE_TAIL_MAX_CHARS):
        self.path = path
        self.max_chars = max_chars
        self.lines: list[str] = []
        self.current_line = ""

    def append(self, chunk: bytes) -> None:
        text = self._strip_escape_sequences(chunk.decode("utf-8", errors="replace"))
        if not text:
            return

        self._apply_terminal_text(text)
        rendered = self._render()
        if not rendered:
            return

        payload = {
            "updatedAt": int(time.time() * 1000),
            "text": rendered,
        }
        tmp_path = self.path.with_suffix(self.path.suffix + ".tmp")
        tmp_path.write_text(json.dumps(payload), encoding="utf-8")
        tmp_path.replace(self.path)

    def cleanup(self) -> None:
        try:
            self.path.unlink(missing_ok=True)
        except Exception:
            pass

    def _strip_escape_sequences(self, text: str) -> str:
        text = OSC_ESCAPE_RE.sub("", text)
        text = CSI_CURSOR_LEFT_RE.sub(self._cursor_left_replacement, text)
        text = CSI_CURSOR_HORIZONTAL_ABSOLUTE_RE.sub("\r", text)
        text = CSI_ERASE_ENTIRE_LINE_RE.sub("\r", text)
        text = ANSI_ESCAPE_RE.sub("", text)
        return TEXTUAL_BRACKETED_PASTE_RE.sub("", text)

    def _cursor_left_replacement(self, match: re.Match) -> str:
        raw_count = match.group(1)
        try:
            count = int(raw_count) if raw_count else 1
        except ValueError:
            count = 1
        return "\b" * max(1, min(count, 500))

    def _apply_terminal_text(self, text: str) -> None:
        for char in text:
            if char == "\r":
                self.current_line = ""
                continue
            if char == "\n":
                self._commit_current_line()
                continue
            if char == "\b":
                self.current_line = self.current_line[:-1]
                continue
            if char == "\t":
                self.current_line += "    "
                continue
            if INLINE_CONTROL_CHAR_RE.match(char):
                continue
            self.current_line += char

    def _commit_current_line(self) -> None:
        line = self.current_line.rstrip()
        if line or (self.lines and self.lines[-1]):
            self.lines.append(line)
        self.current_line = ""

    def _render(self) -> str:
        output_lines = list(self.lines)
        current_line = self.current_line.rstrip()
        if current_line:
            output_lines.append(current_line)

        rendered = "\n".join(output_lines).strip()
        if len(rendered) <= self.max_chars:
            return rendered

        trimmed = rendered[-self.max_chars :]
        newline_index = trimmed.find("\n")
        if newline_index != -1:
            trimmed = trimmed[newline_index + 1 :]
        return trimmed.strip()


class RelayServer:
    def __init__(self, path: Path, child_fd: int, process: subprocess.Popen):
        self.path = path
        self.child_fd = child_fd
        self.process = process
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(path))
        self.server.listen()
        self.server.setblocking(False)
        self.buffers: dict[socket.socket, bytes] = {}

    def _runtime_exit_message(self, *, after_write: bool) -> str | None:
        returncode = self.process.poll()
        if returncode is None:
            return None

        if after_write:
            return f"runtime exited with code {returncode} immediately after injected input"
        return f"runtime exited with code {returncode}"

    def close(self, selector: selectors.BaseSelector) -> None:
        for conn in list(self.buffers.keys()):
            try:
                selector.unregister(conn)
            except Exception:
                pass
            try:
                conn.close()
            except Exception:
                pass
        self.buffers.clear()
        try:
            selector.unregister(self.server)
        except Exception:
            pass
        self.server.close()
        try:
            self.path.unlink(missing_ok=True)
        except Exception:
            pass

    def accept(self, selector: selectors.BaseSelector) -> None:
        conn, _ = self.server.accept()
        conn.setblocking(False)
        self.buffers[conn] = b""
        selector.register(conn, selectors.EVENT_READ, self.read_client)

    def read_client(self, selector: selectors.BaseSelector, conn: socket.socket) -> None:
        try:
            chunk = conn.recv(4096)
        except BlockingIOError:
            return
        if not chunk:
            self._close_client(selector, conn)
            return
        buffer = self.buffers.get(conn, b"") + chunk
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            self._handle_message(conn, line)
        self.buffers[conn] = buffer

    def _close_client(self, selector: selectors.BaseSelector, conn: socket.socket) -> None:
        self.buffers.pop(conn, None)
        try:
            selector.unregister(conn)
        except Exception:
            pass
        try:
            conn.close()
        except Exception:
            pass

    def _handle_message(self, conn: socket.socket, payload: bytes) -> None:
        try:
            runtime_exit = self._runtime_exit_message(after_write=False)
            if runtime_exit:
                conn.sendall(json.dumps({"ok": False, "error": runtime_exit}).encode("utf-8") + b"\n")
                return

            message = json.loads(payload.decode("utf-8"))
            msg_type = message.get("type")
            if msg_type == "sendText":
                text = str(message.get("text", ""))
                segments = message.get("segments")
                press_enter = bool(message.get("pressEnter", True))
                if isinstance(segments, list):
                    self._type_segments(segments, fallback_text=text, press_enter=press_enter)
                else:
                    self._type_text(text, press_enter=press_enter)
                time.sleep(POST_SEND_EXIT_GRACE_SECONDS)
                runtime_exit = self._runtime_exit_message(after_write=True)
                if runtime_exit:
                    conn.sendall(json.dumps({"ok": False, "error": runtime_exit}).encode("utf-8") + b"\n")
                    return
                conn.sendall(b'{"ok":true}\n')
            elif msg_type == "interrupt":
                os.write(self.child_fd, b"\x03")
                time.sleep(POST_INTERRUPT_EXIT_GRACE_SECONDS)
                runtime_exit = self._runtime_exit_message(after_write=True)
                if runtime_exit:
                    conn.sendall(json.dumps({"ok": False, "error": runtime_exit}).encode("utf-8") + b"\n")
                    return
                conn.sendall(b'{"ok":true}\n')
            elif msg_type == "sendInput":
                text = str(message.get("text", ""))
                if text:
                    os.write(self.child_fd, text.encode("utf-8"))
                time.sleep(POST_INPUT_EXIT_GRACE_SECONDS)
                runtime_exit = self._runtime_exit_message(after_write=True)
                if runtime_exit:
                    conn.sendall(json.dumps({"ok": False, "error": runtime_exit}).encode("utf-8") + b"\n")
                    return
                conn.sendall(b'{"ok":true}\n')
            else:
                conn.sendall(b'{"ok":false,"error":"unsupported message"}\n')
        except Exception as exc:
            conn.sendall(json.dumps({"ok": False, "error": str(exc)}).encode("utf-8") + b"\n")

    def _write_text(self, text: str, char_delay: float) -> None:
        if char_delay <= 0:
            os.write(self.child_fd, text.encode("utf-8"))
            return

        for character in text:
            os.write(self.child_fd, character.encode("utf-8"))
            time.sleep(char_delay)

    def _type_text(self, text: str, *, press_enter: bool = True) -> None:
        self._write_text(text, TYPEWRITE_CHAR_DELAY_SECONDS)
        if press_enter:
            os.write(self.child_fd, b"\r")

    def _type_segments(self, segments: list, *, fallback_text: str, press_enter: bool) -> None:
        wrote_any = False
        for raw_segment in segments:
            if not isinstance(raw_segment, dict):
                continue
            text = str(raw_segment.get("text", ""))
            if not text:
                continue
            mode = str(raw_segment.get("mode", "typewrite"))
            char_delay = 0.0 if mode == "burst" else TYPEWRITE_CHAR_DELAY_SECONDS
            self._write_text(text, char_delay)
            wrote_any = True

            try:
                delay_ms = float(raw_segment.get("delayAfterMs", 0))
            except (TypeError, ValueError):
                delay_ms = 0
            if delay_ms > 0:
                time.sleep(delay_ms / 1000.0)

        if not wrote_any and fallback_text:
            self._write_text(fallback_text, TYPEWRITE_CHAR_DELAY_SECONDS)
        if press_enter:
            os.write(self.child_fd, b"\r")


def write_launch_stamp(
    registry_dir: Path,
    runtime: str,
    wrapper: str,
    cwd: str,
    ipc_socket: Path,
    output_tail_path: Path,
    runtime_pid: int,
    thread_id: str | None,
) -> Path:
    registry_dir.mkdir(parents=True, exist_ok=True)
    stamp_path = registry_dir / f"{runtime}-{os.getpid()}.json"
    payload = {
        "runtime": runtime,
        "pid": os.getpid(),
        "runtimePid": runtime_pid,
        "cwd": cwd,
        "launchedAt": int(time.time() * 1000),
        "wrapper": wrapper,
        "ipcSocket": str(ipc_socket),
        "outputTailPath": str(output_tail_path),
        "threadId": thread_id,
    }
    stamp_path.write_text(json.dumps(payload), encoding="utf-8")
    return stamp_path


def write_all(fd: int, payload: bytes) -> None:
    view = memoryview(payload)
    while len(view) > 0:
        try:
            written = os.write(fd, view)
        except BlockingIOError:
            select.select([], [fd], [], 0.1)
            continue
        if written <= 0:
            raise BrokenPipeError("stdout write returned 0 bytes")
        view = view[written:]


def runtime_environment() -> dict[str, str]:
    env = dict(os.environ)
    term = env.get("TERM", "").strip().lower()
    if not term or term == "dumb":
        env["TERM"] = "xterm-256color"
    env.setdefault("COLORTERM", "truecolor")
    return env


def main() -> int:
    args = parse_args()
    registry_dir = Path(args.registry_dir).expanduser()
    relay_dir = registry_dir.parent / "runtime-relays"
    relay_dir.mkdir(parents=True, exist_ok=True)
    socket_path = relay_dir / f"{args.runtime}-{os.getpid()}.sock"
    output_tail_path = relay_dir / f"{args.runtime}-{os.getpid()}.tail.json"
    if socket_path.exists():
        socket_path.unlink()
    if output_tail_path.exists():
        output_tail_path.unlink()

    master_fd, slave_fd = pty.openpty()
    stdin_fd = sys.stdin.fileno()
    stdin_is_tty = os.isatty(stdin_fd)
    if stdin_is_tty:
        try:
            sync_window_size(stdin_fd, slave_fd)
        except OSError:
            pass
    process = subprocess.Popen(
        args.command,
        cwd=args.cwd,
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        env=runtime_environment(),
        close_fds=True,
        start_new_session=True,
    )
    os.close(slave_fd)

    stamp_path = write_launch_stamp(
        registry_dir=registry_dir,
        runtime=args.runtime,
        wrapper=args.wrapper,
        cwd=args.cwd,
        ipc_socket=socket_path,
        output_tail_path=output_tail_path,
        runtime_pid=process.pid,
        thread_id=args.thread_id,
    )

    selector = selectors.DefaultSelector()
    relay = RelayServer(socket_path, master_fd, process)
    live_tail = LiveTailBuffer(output_tail_path)
    selector.register(relay.server, selectors.EVENT_READ, relay.accept)

    stdout_fd = sys.stdout.fileno()
    if not os.get_blocking(stdout_fd):
        os.set_blocking(stdout_fd, True)
    old_tty_state = None
    stdin_registered = False

    if stdin_is_tty:
        old_tty_state = termios.tcgetattr(stdin_fd)
        tty.setraw(stdin_fd)
        if os.get_blocking(stdin_fd):
            os.set_blocking(stdin_fd, False)
        selector.register(stdin_fd, selectors.EVENT_READ, "stdin")
        stdin_registered = True
    selector.register(master_fd, selectors.EVENT_READ, "pty")

    def cleanup() -> None:
        if stdin_registered:
            try:
                selector.unregister(stdin_fd)
            except Exception:
                pass
        try:
            selector.unregister(master_fd)
        except Exception:
            pass
        relay.close(selector)
        selector.close()
        try:
            os.close(master_fd)
        except Exception:
            pass
        try:
            stamp_path.unlink(missing_ok=True)
        except Exception:
            pass
        live_tail.cleanup()
        if old_tty_state is not None:
            termios.tcsetattr(stdin_fd, termios.TCSADRAIN, old_tty_state)

    def forward_signal(signum, _frame) -> None:
        try:
            process.send_signal(signum)
        except Exception:
            pass

    signal.signal(signal.SIGTERM, forward_signal)
    signal.signal(signal.SIGINT, forward_signal)
    if stdin_is_tty:
        def forward_winch(_signum, _frame) -> None:
            try:
                sync_window_size(stdin_fd, master_fd)
            except OSError:
                pass

        signal.signal(signal.SIGWINCH, forward_winch)
        forward_winch(signal.SIGWINCH, None)

    try:
        while True:
            if process.poll() is not None:
                break
            for key, _ in selector.select(timeout=0.1):
                if key.data == "stdin":
                    try:
                        chunk = os.read(stdin_fd, 4096)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        try:
                            selector.unregister(stdin_fd)
                        except Exception:
                            pass
                        stdin_registered = False
                        continue
                    os.write(master_fd, chunk)
                elif key.data == "pty":
                    try:
                        chunk = os.read(master_fd, 4096)
                    except OSError:
                        chunk = b""
                    if not chunk:
                        break
                    live_tail.append(chunk)
                    try:
                        write_all(stdout_fd, chunk)
                    except BrokenPipeError:
                        return process.wait()
                else:
                    callback = key.data
                    if key.fileobj == relay.server:
                        callback(selector)
                    else:
                        callback(selector, key.fileobj)
        return process.wait()
    finally:
        cleanup()


if __name__ == "__main__":
    sys.exit(main())
