#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/migrate-sirix-agents-to-files.sh [options]

Migrate legacy inline Sirix Agent config from config.toml into SIRIX_HOME/agents/*.toml.

Options:
  --sirix-home PATH       Sirix home directory. Default: $SIRIX_HOME or ~/.sirix.
  --config PATH           Direct config.toml path. Overrides --sirix-home.
  --override-agent-files  Overwrite same-id files in agents/*.toml.
  --dry-run               Print planned changes without writing files.
  -h, --help              Show this help.

Behavior:
  - Complete [[agents]] blocks are written to SIRIX_HOME/agents/<agent-id>.toml.
  - Existing same-id agent files are kept unless --override-agent-files is set.
  - Migrated [[agents]] blocks are removed from config.toml.
  - Orphan [agents.*] / [[agents.*]] fragments are removed from config.toml.
  - A timestamped config.toml backup is written before in-place changes.
USAGE
}

SIRIX_HOME_DIR="${SIRIX_HOME:-$HOME/.sirix}"
CONFIG_PATH=""
OVERRIDE_AGENT_FILES="0"
DRY_RUN="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sirix-home)
      SIRIX_HOME_DIR="${2:-}"; shift 2 ;;
    --config)
      CONFIG_PATH="${2:-}"; shift 2 ;;
    --override-agent-files)
      OVERRIDE_AGENT_FILES="1"; shift ;;
    --dry-run)
      DRY_RUN="1"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

if [[ -z "${CONFIG_PATH}" ]]; then
  CONFIG_PATH="${SIRIX_HOME_DIR}/config.toml"
fi

python3 - "${CONFIG_PATH}" "${OVERRIDE_AGENT_FILES}" "${DRY_RUN}" <<'PY'
import difflib
import json
import re
import shutil
import sys
import time
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:
    tomllib = None

config_path = Path(sys.argv[1]).expanduser()
override_agent_files = sys.argv[2] == "1"
dry_run = sys.argv[3] == "1"
sirix_home = config_path.parent
agents_dir = sirix_home / "agents"


def parse_toml_header(line: str):
    stripped = line.strip()
    match = re.match(r'^\[\[([^\]]+)\]\]\s*(?:#.*)?$', stripped)
    if match:
        return match.group(1).strip(), True
    match = re.match(r'^\[([^\]]+)\]\s*(?:#.*)?$', stripped)
    if match:
        return match.group(1).strip(), False
    return None


def split_config_and_agent_blocks(text: str):
    kept = []
    agent_blocks = []
    orphan_headers = []
    current = None
    skipping_orphan_agent_child = False

    def process_outside(line: str, header):
        nonlocal current, skipping_orphan_agent_child
        if header:
            name, is_array = header
            if is_array and name == "agents":
                current = [line]
                return
            if name.startswith("agents."):
                skipping_orphan_agent_child = True
                orphan_headers.append(line.strip())
                return
        kept.append(line)

    for line in text.splitlines(keepends=True):
        header = parse_toml_header(line)
        if current is not None:
            if header:
                name, is_array = header
                if is_array and name == "agents":
                    agent_blocks.append("".join(current))
                    current = [line]
                    continue
                if name.startswith("agents."):
                    current.append(line)
                    continue
                agent_blocks.append("".join(current))
                current = None
                process_outside(line, header)
                continue
            current.append(line)
            continue

        if skipping_orphan_agent_child:
            if not header:
                continue
            name, _is_array = header
            if name.startswith("agents."):
                orphan_headers.append(line.strip())
                continue
            skipping_orphan_agent_child = False
            process_outside(line, header)
            continue

        process_outside(line, header)

    if current is not None:
        agent_blocks.append("".join(current))

    return "".join(kept).rstrip() + "\n", agent_blocks, orphan_headers


def toml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def agent_id_from_block(block: str) -> str:
    match = re.search(r'^\s*id\s*=\s*"([^"]+)"\s*$', block, flags=re.MULTILINE)
    return match.group(1).strip() if match else ""


def is_windows_reserved_file_stem(stem: str) -> bool:
    upper = stem.upper()
    if upper in {"CON", "PRN", "AUX", "NUL"}:
        return True
    for prefix in ("COM", "LPT"):
        if upper.startswith(prefix) and upper[len(prefix):] in {"1", "2", "3", "4", "5", "6", "7", "8", "9"}:
            return True
    return False


def safe_file_stem(agent_id: str) -> str:
    value = []
    for byte in agent_id.encode("utf-8"):
        char = chr(byte)
        if char.isascii() and (char.isalnum() or char in "_-"):
            value.append(char)
        else:
            value.append(f"~{byte:02x}")
    stem = "".join(value) or "agent"
    if is_windows_reserved_file_stem(stem):
        stem += "~"
    return stem


def agent_body_from_block(block: str) -> str:
    body = re.sub(r'^\[\[agents\]\]\n', "", block.strip(), count=1)
    body = re.sub(r'(?m)^\[agents\.', "[", body)
    body = re.sub(r'(?m)^\[\[agents\.', "[[", body)
    return body.rstrip() + "\n"


def existing_agent_files_by_id(directory: Path):
    by_id = {}
    if not directory.is_dir():
        return by_id
    for path in sorted(directory.glob("*.toml")):
        try:
            aid = agent_id_from_block(path.read_text(encoding="utf-8"))
        except OSError:
            continue
        if aid:
            by_id.setdefault(aid, path)
    return by_id


def backup_config_file(path: Path) -> Path:
    stamp = time.strftime("%Y%m%d%H%M%S")
    backup = path.with_suffix(path.suffix + f".bak-agent-migrate-{stamp}")
    suffix = 2
    while backup.exists():
        backup = path.with_suffix(path.suffix + f".bak-agent-migrate-{stamp}-{suffix}")
        suffix += 1
    shutil.copy2(path, backup)
    return backup


if not config_path.exists():
    raise SystemExit(f"config not found: {config_path}")

original = config_path.read_text(encoding="utf-8")
repaired_config, agent_blocks, orphan_headers = split_config_and_agent_blocks(original)
existing_files = existing_agent_files_by_id(agents_dir)

planned_writes = []
skipped_existing = []
skipped_invalid = []
for block in agent_blocks:
    aid = agent_id_from_block(block)
    if not aid:
        skipped_invalid.append("inline [[agents]] block without id")
        continue
    target = existing_files.get(aid) or agents_dir / f"{safe_file_stem(aid)}.toml"
    if target.exists() and not override_agent_files:
        skipped_existing.append((aid, target))
        continue
    body = agent_body_from_block(block)
    if tomllib is not None:
        try:
            tomllib.loads(body)
        except Exception as exc:
            skipped_invalid.append(f"{aid}: generated agent file is invalid TOML: {exc}")
            continue
    planned_writes.append((aid, target, body))

if tomllib is not None:
    tomllib.loads(repaired_config)

changed_config = repaired_config != original
if not agent_blocks and not orphan_headers:
    print(f"No inline Agent blocks or orphan agents.* fragments found in {config_path}")
elif dry_run:
    print(f"Would migrate inline Agent blocks: {len(agent_blocks)}")
    print(f"Would write agent files: {len(planned_writes)}")
    print(f"Would skip existing same-id files: {len(skipped_existing)}")
    print(f"Would remove orphan agents.* headers: {len(orphan_headers)}")
    for aid, target, _body in planned_writes:
        print(f"  write {aid} -> {target}")
    for aid, target in skipped_existing:
        print(f"  skip existing {aid} -> {target}")
    for item in skipped_invalid:
        print(f"  invalid {item}")
    if changed_config:
        print("\n--- config diff (dry run) ---")
        sys.stdout.writelines(
            difflib.unified_diff(
                original.splitlines(keepends=True),
                repaired_config.splitlines(keepends=True),
                fromfile=str(config_path),
                tofile=str(config_path) + ".migrated",
            )
        )
else:
    backup = backup_config_file(config_path) if changed_config else None
    agents_dir.mkdir(parents=True, exist_ok=True)
    for _aid, target, body in planned_writes:
        target.write_text(body, encoding="utf-8")
    if changed_config:
        config_path.write_text(repaired_config, encoding="utf-8")
    print(f"Inline Agent blocks found: {len(agent_blocks)}")
    print(f"Agent files written: {len(planned_writes)}")
    print(f"Existing same-id files skipped: {len(skipped_existing)}")
    print(f"Orphan agents.* headers removed: {len(orphan_headers)}")
    if backup:
        print(f"Backup written: {backup}")
    for aid, target, _body in planned_writes:
        print(f"  wrote {aid} -> {target}")
    for aid, target in skipped_existing:
        print(f"  skipped existing {aid} -> {target}")
    for item in skipped_invalid:
        print(f"  invalid {item}")
PY
