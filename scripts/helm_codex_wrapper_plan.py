#!/usr/bin/env python3
import argparse
import os
import re
import shlex
import sys
from dataclasses import dataclass


COMMANDS = {
    "exec",
    "e",
    "review",
    "login",
    "logout",
    "mcp",
    "mcp-server",
    "app-server",
    "app",
    "completion",
    "sandbox",
    "debug",
    "apply",
    "a",
    "resume",
    "fork",
    "cloud",
    "features",
    "help",
}

VALUE_OPTIONS = {
    "-c",
    "--config",
    "--enable",
    "--disable",
    "--remote",
    "--remote-auth-token-env",
    "-i",
    "--image",
    "-m",
    "--model",
    "--local-provider",
    "-p",
    "--profile",
    "-s",
    "--sandbox",
    "-a",
    "--ask-for-approval",
    "-C",
    "--cd",
    "--add-dir",
}

UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


@dataclass
class Plan:
    runtime_cwd: str
    bootstrap: bool
    resume_target: str
    thread_id: str
    model: str
    thread_arg_index: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Plan helm Codex shell wrapper launch behavior.")
    parser.add_argument("--cwd", required=True)
    parser.add_argument("codex_args", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.codex_args and args.codex_args[0] == "--":
        args.codex_args = args.codex_args[1:]
    return args


def shell_assign(name: str, value: str) -> str:
    return f"{name}={shlex.quote(value)}"


def resolve_cwd(base_cwd: str, candidate: str) -> tuple[str, bool]:
    expanded = os.path.expanduser(candidate)
    absolute = os.path.abspath(expanded if os.path.isabs(expanded) else os.path.join(base_cwd, expanded))
    return absolute, os.path.isdir(absolute)


def read_value(args: list[str], index: int, option: str) -> tuple[str | None, int]:
    if option.startswith("--") and "=" in option:
        return option.split("=", 1)[1], index + 1

    if option.startswith("-") and not option.startswith("--") and len(option) > 2:
        return option[2:], index + 1

    if index + 1 >= len(args):
        return None, len(args)

    return args[index + 1], index + 2


def scan_common_options(args: list[str], base_cwd: str) -> dict[str, object]:
    index = 0
    effective_cwd = base_cwd
    cwd_valid = True
    model = ""
    saw_help = False
    saw_version = False
    saw_remote = False

    while index < len(args):
        token = args[index]
        if token == "--":
            break
        if not token.startswith("-") or token == "-":
            break

        if token in {"-h", "--help"}:
            saw_help = True
            index += 1
            continue

        if token in {"-V", "--version"}:
            saw_version = True
            index += 1
            continue

        option_name = token.split("=", 1)[0] if token.startswith("--") else token[:2]
        if option_name not in VALUE_OPTIONS:
            index += 1
            continue

        value, next_index = read_value(args, index, token)
        if option_name == "--remote" and value is not None:
            saw_remote = True
        if option_name in {"-m", "--model"} and value is not None:
            model = value
        if option_name in {"-C", "--cd"} and value is not None:
            resolved, valid = resolve_cwd(base_cwd, value)
            if valid:
                effective_cwd = resolved
            else:
                cwd_valid = False
        index = next_index

    return {
        "effective_cwd": effective_cwd,
        "cwd_valid": cwd_valid,
        "model": model,
        "saw_help": saw_help,
        "saw_version": saw_version,
        "saw_remote": saw_remote,
        "next_index": index,
    }


def parse_resume_target(args: list[str]) -> tuple[str, int]:
    index = 0
    saw_last = False

    while index < len(args):
        token = args[index]
        if token == "--":
            index += 1
            break
        if not token.startswith("-") or token == "-":
            break

        if token == "--last":
            saw_last = True
            index += 1
            continue

        option_name = token.split("=", 1)[0] if token.startswith("--") else token[:2]
        if option_name not in VALUE_OPTIONS:
            index += 1
            continue

        _, next_index = read_value(args, index, token)
        index = next_index

    if saw_last or index >= len(args):
        return "", -1

    return args[index].strip(), index


def merge_scans(primary: dict[str, object], secondary: dict[str, object]) -> dict[str, object]:
    merged = dict(primary)
    if bool(secondary["cwd_valid"]):
        merged["effective_cwd"] = secondary["effective_cwd"]
    elif not bool(primary["cwd_valid"]):
        merged["effective_cwd"] = primary["effective_cwd"]
    merged["cwd_valid"] = bool(primary["cwd_valid"]) and bool(secondary["cwd_valid"])
    merged["model"] = str(secondary["model"] or primary["model"])
    merged["saw_help"] = bool(primary["saw_help"]) or bool(secondary["saw_help"])
    merged["saw_version"] = bool(primary["saw_version"]) or bool(secondary["saw_version"])
    merged["saw_remote"] = bool(primary["saw_remote"]) or bool(secondary["saw_remote"])
    return merged


def build_plan(base_cwd: str, codex_args: list[str]) -> Plan:
    base_cwd = os.path.abspath(base_cwd)
    scan = scan_common_options(codex_args, base_cwd)
    runtime_cwd = scan["effective_cwd"] if scan["cwd_valid"] else base_cwd
    next_index = int(scan["next_index"])

    first_positional = ""
    if next_index < len(codex_args):
        if codex_args[next_index] == "--":
            if next_index + 1 < len(codex_args):
                first_positional = codex_args[next_index + 1]
        else:
            first_positional = codex_args[next_index]

    if first_positional in COMMANDS:
        effective_scan = scan
        if first_positional == "resume":
            resume_scan = scan_common_options(codex_args[next_index + 1 :], runtime_cwd)
            effective_scan = merge_scans(scan, resume_scan)
            runtime_cwd = effective_scan["effective_cwd"] if effective_scan["cwd_valid"] else base_cwd
            if not effective_scan["saw_remote"]:
                resume_target, thread_arg_index = parse_resume_target(codex_args[next_index + 1 :])
                return Plan(
                    runtime_cwd=runtime_cwd,
                    bootstrap=False,
                    resume_target=resume_target,
                    thread_id=resume_target if UUID_RE.match(resume_target) else "",
                    model=str(effective_scan["model"]),
                    thread_arg_index=thread_arg_index + next_index + 1 if thread_arg_index >= 0 else -1,
                )

        return Plan(
            runtime_cwd=runtime_cwd,
            bootstrap=False,
            resume_target="",
            thread_id="",
            model=str(effective_scan["model"]),
            thread_arg_index=-1,
        )

    bootstrap = (
        not bool(scan["saw_help"])
        and not bool(scan["saw_version"])
        and not bool(scan["saw_remote"])
        and bool(scan["cwd_valid"])
    )

    return Plan(
        runtime_cwd=runtime_cwd,
        bootstrap=bootstrap,
        resume_target="",
        thread_id="",
        model=str(scan["model"]),
        thread_arg_index=-1,
    )


def main() -> int:
    args = parse_args()
    plan = build_plan(args.cwd, list(args.codex_args))
    print(shell_assign("HELM_WRAPPER_RUNTIME_CWD", plan.runtime_cwd))
    print(shell_assign("HELM_WRAPPER_BOOTSTRAP", "1" if plan.bootstrap else "0"))
    print(shell_assign("HELM_WRAPPER_RESUME_TARGET", plan.resume_target))
    print(shell_assign("HELM_WRAPPER_THREAD_ID", plan.thread_id))
    print(shell_assign("HELM_WRAPPER_BOOTSTRAP_MODEL", plan.model))
    print(shell_assign("HELM_WRAPPER_THREAD_ARG_INDEX", str(plan.thread_arg_index)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
