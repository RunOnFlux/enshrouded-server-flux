#!/usr/bin/env python3
"""EML mods for the Enshrouded server: what to load, the folder EML reads, and what happened.

EML (the Enshrouded Mod Loader, github.com/Brabb3l/kfc-parser) is a proxy dbghelp.dll. When the
game loads it, it reads every entry of `<game dir>/mods` (a folder, or a `.zip` file, holding a
`mod.json` at its root; anything starting with a dot is skipped), runs the mods' Lua and writes
the result into the game's own data files before the server starts.

It has no way to fail quietly. ANY error, a bad `mod.json` included, ends in a Rust panic whose
handler opens a Windows message box ("Fatal error"), and on a server with no screen that is a
process that never binds its port. So nothing reaches EML that it would refuse:

  plan     reads the customer's library (the synced `mods` volume), checks every entry the way
           EML would and prints the plan: which entries load, which are off, which are refused
           and why. The fingerprint names the set that loads, for the safe mode.
  sync     makes `<game dir>/mods` hold exactly the entries the plan loads. The library itself is
           never handed to EML: EML writes caches beside what it reads, and a library entry it
           refuses would stop the server.
  report   reads EML's log (JSON lines) for one start: the errors, and the patch count.
  status   writes the status file the games hub's Mods tab reads.

Standard library only: the base image has python3 and nothing else.
"""

import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import time
import zipfile

# The manifest rules, as EML enforces them (mod-loader-base/src/registry/manifest.rs, serde).
ID_RE = re.compile(r"^[a-z][a-z0-9_-]*$")
CAPABILITIES = {"export", "patch", "runtime", "runtime-register-dll"}
SEMVER_RE = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)
# One comparator of a Cargo-style version requirement: `>=1.2`, `^1`, `~1.2.3`, `1.*`, `*`.
COMPARATOR_RE = re.compile(
    r"^(=|>=|<=|>|<|~|\^)?\s*"
    r"(\*|[xX]|0|[1-9]\d*)(?:\.(\*|[xX]|0|[1-9]\d*))?(?:\.(\*|[xX]|0|[1-9]\d*))?"
    r"(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$"
)

DISABLED_SUFFIX = ".disabled"
MANIFEST = "mod.json"
# What `sync` put into the folder EML reads. A dot file, so EML skips it. Whatever is listed here
# came from the library and is never "adopted" back into it: that would undo the customer turning
# a mod off (an earlier copy is still in the folder when the next start runs without mods).
SYNCED = ".flux-synced.json"


# ---------------------------------------------------------------------------------------------
# Versions
# ---------------------------------------------------------------------------------------------

def parse_version(text):
    """(major, minor, patch, pre) for a strict semver string, or None."""
    m = SEMVER_RE.match(text or "")
    if not m:
        return None
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4) or "")


def _cmp_key(v):
    # A pre-release sorts below its release; good enough for a dependency warning.
    major, minor, patch, pre = v
    return (major, minor, patch, 0 if pre else 1, pre)


def parse_requirement(text):
    """The comparators of a version requirement, or None when EML would refuse it."""
    if not isinstance(text, str) or not text.strip():
        return None
    out = []
    for part in text.split(","):
        part = part.strip()
        m = COMPARATOR_RE.match(part)
        if not m:
            return None
        op, a, b, c, pre = m.groups()
        nums = []
        for x in (a, b, c):
            if x is None or x in ("*", "x", "X"):
                break
            nums.append(int(x))
        out.append((op or "", nums, pre or ""))
    return out


def requirement_matches(req, version):
    """True when version satisfies every comparator (Cargo semantics, pre-releases simplified)."""
    v = _cmp_key(version)
    for op, nums, pre in req:
        n = len(nums)
        lo = tuple(nums + [0] * (3 - n))
        if op in ("", "^"):
            if n == 0:
                continue
            if n == 1 or lo[0] > 0:
                hi = (lo[0] + 1, 0, 0)
            elif n == 2 or lo[1] > 0:
                hi = (0, lo[1] + 1, 0)
            else:
                hi = (0, 0, lo[2] + 1)
            if not (_cmp_key(lo + (pre,)) <= v < _cmp_key(hi + ("",))):
                return False
        elif op == "~":
            hi = (lo[0] + 1, 0, 0) if n <= 1 else (lo[0], lo[1] + 1, 0)
            if not (_cmp_key(lo + (pre,)) <= v < _cmp_key(hi + ("",))):
                return False
        elif op == "=":
            if n == 3:
                if v != _cmp_key(lo + (pre,)):
                    return False
            else:
                hi = (lo[0] + 1, 0, 0) if n == 1 else (lo[0], lo[1] + 1, 0)
                if n and not (_cmp_key(lo + ("",)) <= v < _cmp_key(hi + ("",))):
                    return False
        elif op in (">", ">="):
            if n == 0:
                continue
            if n < 3 and op == ">":
                # >1.2 means >=1.3.0
                bumped = list(lo)
                bumped[n - 1] += 1
                if v < _cmp_key(tuple(bumped) + ("",)):
                    return False
            elif op == ">" and not v > _cmp_key(lo + (pre,)):
                return False
            elif op == ">=" and not v >= _cmp_key(lo + (pre,)):
                return False
        elif op in ("<", "<="):
            if n == 0:
                continue
            if n < 3 and op == "<=":
                bumped = list(lo)
                bumped[n - 1] += 1
                if not v < _cmp_key(tuple(bumped) + ("",)):
                    return False
            elif op == "<" and not v < _cmp_key(lo + (pre,)):
                return False
            elif op == "<=" and not v <= _cmp_key(lo + (pre,)):
                return False
    return True


# ---------------------------------------------------------------------------------------------
# One library entry
# ---------------------------------------------------------------------------------------------

def check_manifest(data):
    """(manifest summary, None) when EML would accept it, or (partial summary, reason)."""
    if not isinstance(data, dict):
        return {}, "mod.json is not a JSON object"
    summary = {
        "id": data.get("id") if isinstance(data.get("id"), str) else None,
        "name": data.get("name") if isinstance(data.get("name"), str) else None,
        "version": data.get("version") if isinstance(data.get("version"), str) else None,
        "description": data.get("description") if isinstance(data.get("description"), str) else None,
        "authors": [a for a in data.get("authors") or [] if isinstance(a, str)]
        if isinstance(data.get("authors"), list) else [],
        "capabilities": [],
        "dependencies": [],
    }
    if not summary["id"]:
        return summary, "mod.json has no \"id\""
    if not ID_RE.match(summary["id"]):
        return summary, (
            f"the id \"{summary['id']}\" is not allowed: lowercase letters, digits, - and _ only, "
            "starting with a letter"
        )
    if not summary["name"]:
        return summary, "mod.json has no \"name\""
    if not summary["version"]:
        return summary, "mod.json has no \"version\""
    if not parse_version(summary["version"]):
        return summary, f"the version \"{summary['version']}\" is not a semantic version like 1.0.0"
    caps = data.get("capabilities", [])
    if not isinstance(caps, list) or not all(isinstance(c, str) for c in caps):
        return summary, "\"capabilities\" must be a list of names"
    unknown = [c for c in caps if c not in CAPABILITIES]
    if unknown:
        return summary, f"unknown capability \"{unknown[0]}\" (this EML knows {', '.join(sorted(CAPABILITIES))})"
    summary["capabilities"] = caps
    deps = data.get("dependencies", [])
    if not isinstance(deps, list):
        return summary, "\"dependencies\" must be a list"
    for dep in deps:
        if not isinstance(dep, dict) or not isinstance(dep.get("id"), str):
            return summary, "a dependency has no \"id\""
        req = parse_requirement(dep.get("version"))
        if req is None:
            return summary, f"the dependency \"{dep.get('id')}\" has no valid version requirement"
        optional = dep.get("optional")
        if optional is not None and not isinstance(optional, bool):
            return summary, f"\"optional\" of the dependency \"{dep['id']}\" must be true or false"
        summary["dependencies"].append({"id": dep["id"], "version": dep["version"], "optional": bool(optional)})
    for key in ("description", "license", "icon"):
        if key in data and data[key] is not None and not isinstance(data[key], str):
            return summary, f"\"{key}\" must be text"
    if "authors" in data and not isinstance(data["authors"], list):
        return summary, "\"authors\" must be a list"
    return summary, None


def read_entry(path):
    """(kind, manifest summary, reason) for one library entry; kind None for a non-mod file."""
    name = os.path.basename(path)
    if os.path.isdir(path):
        kind = "dir"
        manifest = os.path.join(path, MANIFEST)
        if not os.path.isfile(manifest):
            return kind, {}, "the folder has no mod.json at its top level"
        try:
            with open(manifest, "rb") as f:
                raw = f.read()
        except OSError as e:
            return kind, {}, f"mod.json could not be read: {e.strerror}"
    elif os.path.isfile(path) and re.search(r"\.zip(" + re.escape(DISABLED_SUFFIX) + r")?$", name, re.I):
        kind = "zip"
        try:
            with zipfile.ZipFile(path) as z:
                try:
                    raw = z.read(MANIFEST)
                except KeyError:
                    return kind, {}, "the zip has no mod.json at its top level"
                bad = z.testzip()
                if bad:
                    return kind, {}, f"the zip is damaged ({bad})"
        except (zipfile.BadZipFile, OSError) as e:
            return kind, {}, f"not a readable zip file ({e})"
    else:
        return None, {}, None
    try:
        data = json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, ValueError) as e:
        return kind, {}, f"mod.json is not valid JSON ({e})"
    summary, reason = check_manifest(data)
    return kind, summary, reason


def entry_digest(path):
    h = hashlib.sha256()
    if os.path.isdir(path):
        for root, dirs, files in os.walk(path):
            dirs.sort()
            for fn in sorted(files):
                full = os.path.join(root, fn)
                h.update(os.path.relpath(full, path).encode())
                with open(full, "rb") as f:
                    for chunk in iter(lambda: f.read(1 << 20), b""):
                        h.update(chunk)
    else:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------------------------------------
# The plan
# ---------------------------------------------------------------------------------------------

def make_plan(library):
    mods = []
    try:
        names = sorted(os.listdir(library))
    except OSError:
        names = []
    for name in names:
        if name.startswith("."):
            continue
        path = os.path.join(library, name)
        kind, summary, reason = read_entry(path)
        if kind is None:
            continue
        enabled = not name.lower().endswith(DISABLED_SUFFIX)
        entry = {"entry": name, "kind": kind, "enabled": enabled, **summary}
        if reason:
            entry["state"], entry["reason"] = "invalid", reason
        elif not enabled:
            entry["state"] = "off"
        else:
            entry["state"] = "active"
        mods.append(entry)

    # The same id twice stops EML (DuplicateModId). The first by name keeps it.
    seen = {}
    for m in mods:
        if m["state"] != "active":
            continue
        if m["id"] in seen:
            m["state"], m["reason"] = "duplicate", f"another active mod ({seen[m['id']]}) has the id \"{m['id']}\""
        else:
            seen[m["id"]] = m["entry"]

    # A required dependency that is not loaded is a Lua `require` failing inside EML, which is
    # the same message box. Repeated, because dropping one mod can strand another.
    changed = True
    while changed:
        changed = False
        active = {m["id"]: m for m in mods if m["state"] == "active"}
        for m in mods:
            if m["state"] != "active":
                continue
            for dep in m.get("dependencies") or []:
                if dep["optional"]:
                    continue
                if dep["id"] not in active:
                    m["state"] = "missing-dependency"
                    m["reason"] = f"needs the mod \"{dep['id']}\" ({dep['version']}), which is not installed and on"
                    changed = True
                    break
    # A dependency at the wrong version is not something EML checks; say so, do not refuse.
    active = {m["id"]: m for m in mods if m["state"] == "active"}
    for m in mods:
        if m["state"] != "active":
            continue
        for dep in m.get("dependencies") or []:
            other = active.get(dep["id"])
            if other and not requirement_matches(parse_requirement(dep["version"]), parse_version(other["version"])):
                m["warning"] = f"wants {dep['id']} {dep['version']}, installed is {other['version']}"

    loaded = [m for m in mods if m["state"] == "active"]
    h = hashlib.sha256()
    for m in loaded:
        h.update(m["entry"].encode() + b"\0" + entry_digest(os.path.join(library, m["entry"])).encode() + b"\0")
    return {
        "mods": mods,
        "active": [m["entry"] for m in loaded],
        "fingerprint": h.hexdigest()[:16] if loaded else "",
    }


# ---------------------------------------------------------------------------------------------
# The folder EML reads
# ---------------------------------------------------------------------------------------------

def _same_file(a, b):
    try:
        sa, sb = os.stat(a), os.stat(b)
    except OSError:
        return False
    return sa.st_size == sb.st_size and int(sa.st_mtime) == int(sb.st_mtime)


def _read_synced(runtime):
    try:
        with open(os.path.join(runtime, SYNCED)) as f:
            names = json.load(f)
        return set(n for n in names if isinstance(n, str))
    except (OSError, ValueError, TypeError):
        return set()


def _write_synced(runtime, names):
    with open(os.path.join(runtime, SYNCED), "w") as f:
        json.dump(sorted(names), f)


def sync_runtime(library, runtime, active):
    """Make `runtime` hold copies of exactly the `active` library entries. Prints what changed."""
    os.makedirs(runtime, exist_ok=True)
    wanted = set(active)
    changes = []
    for name in sorted(os.listdir(runtime)):
        if name in wanted or name == SYNCED:
            continue
        path = os.path.join(runtime, name)
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path, ignore_errors=True)
        else:
            os.remove(path)
        changes.append(f"removed {name}")
    for name in active:
        src, dst = os.path.join(library, name), os.path.join(runtime, name)
        if os.path.isdir(src):
            # A folder is copied whole each time it changes; mods are small.
            if os.path.isdir(dst) and entry_digest(src) == entry_digest(dst):
                continue
            if os.path.lexists(dst):
                shutil.rmtree(dst) if os.path.isdir(dst) and not os.path.islink(dst) else os.remove(dst)
            shutil.copytree(src, dst, copy_function=shutil.copy2)
            changes.append(f"copied {name}")
        else:
            if _same_file(src, dst):
                continue
            if os.path.isdir(dst) and not os.path.islink(dst):
                shutil.rmtree(dst)
            shutil.copy2(src, dst)
            changes.append(f"copied {name}")
    _write_synced(runtime, wanted)
    return changes


def clear_runtime(runtime):
    """Remove what `sync` put into `runtime`, and nothing else. Prints what went."""
    gone = []
    for name in sorted(_read_synced(runtime)):
        path = os.path.join(runtime, name)
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path, ignore_errors=True)
        elif os.path.lexists(path):
            os.remove(path)
        else:
            continue
        gone.append(name)
    if os.path.isdir(runtime):
        _write_synced(runtime, [])
    return gone


def adopt_strays(library, runtime):
    """Mods someone put straight into `<game dir>/mods` (the Files tab, before the library
    existed) are moved into the library, so the next sync does not delete them. Prints them."""
    moved = []
    if not os.path.isdir(runtime) or not os.path.isdir(library):
        return moved
    ours = _read_synced(runtime)
    in_library = {n.lower() for n in os.listdir(library)}
    for name in sorted(os.listdir(runtime)):
        if name.startswith(".") or name in ours:
            continue
        base = name[: -len(DISABLED_SUFFIX)] if name.lower().endswith(DISABLED_SUFFIX) else name
        if base.lower() in in_library or (base + DISABLED_SUFFIX).lower() in in_library:
            continue
        src = os.path.join(runtime, name)
        kind, _, _ = read_entry(src)
        if kind is None:
            continue
        dst = os.path.join(library, name)
        if os.path.lexists(dst):
            continue
        try:
            shutil.move(src, dst)
            moved.append(name)
        except OSError:
            pass
    return moved


# ---------------------------------------------------------------------------------------------
# EML's own log, and the status file
# ---------------------------------------------------------------------------------------------

def read_report(logdir):
    """Errors and the patch count from EML's JSON-lines log files in `logdir`."""
    report = {"errors": [], "applied": None, "skipped": False, "ran": []}
    try:
        files = sorted(f for f in os.listdir(logdir) if f.endswith("eml.log"))
    except OSError:
        return report
    for fn in files:
        try:
            with open(os.path.join(logdir, fn), encoding="utf-8", errors="replace") as f:
                lines = f.readlines()
        except OSError:
            continue
        for line in lines:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            fields = rec.get("fields") or {}
            msg = str(fields.get("message", ""))
            level = str(rec.get("level", "")).upper()
            if level == "ERROR":
                detail = fields.get("report") or fields.get("error") or ""
                text = f"{msg}: {detail}" if detail else msg
                if text and text not in report["errors"]:
                    report["errors"].append(text[:2000])
            m = re.search(r"Applied (\d+) patches", msg)
            if m:
                report["applied"] = int(m.group(1))
            if "No changes detected" in msg:
                report["skipped"] = True
            if msg == "Running mod" and fields.get("mod_id"):
                report["ran"].append(str(fields["mod_id"]))
    return report


def write_status(out, plan, mode, phase, message, loader, report=None):
    status = {
        "schema": 1,
        "loader": loader,
        "mode": mode,
        "phase": phase,
        "message": message,
        "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "fingerprint": plan.get("fingerprint", ""),
        "mods": {
            m["entry"]: {k: m.get(k) for k in (
                "id", "name", "version", "description", "authors", "state", "reason", "warning", "enabled", "kind",
            ) if m.get(k) not in (None, [], "")}
            for m in plan.get("mods", [])
        },
    }
    if report:
        status["applied"] = report.get("applied")
        status["errors"] = report.get("errors", [])[:5]
    # EML names a failing mod's chunk `mods.<id>`: the mod the customer has to fix or turn off.
    m = re.search(r"mods\.([a-z][a-z0-9_-]*)", " ".join([message or ""] + status.get("errors", [])))
    if m:
        status["failedMod"] = m.group(1)
    d = os.path.dirname(out) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".mods-status.")
    with os.fdopen(fd, "w") as f:
        json.dump(status, f, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, out)


# ---------------------------------------------------------------------------------------------

def main(argv):
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, args = argv[0], argv[1:]
    if cmd == "plan":          # plan <library>
        json.dump(make_plan(args[0]), sys.stdout)
        print()
        return 0
    if cmd == "sync":          # sync <library> <runtime> <plan.json>
        with open(args[2]) as f:
            plan = json.load(f)
        for line in sync_runtime(args[0], args[1], plan["active"]):
            print(line)
        return 0
    if cmd == "clear":         # clear <runtime>
        for name in clear_runtime(args[0]):
            print(name)
        return 0
    if cmd == "adopt":         # adopt <library> <runtime>
        for name in adopt_strays(args[0], args[1]):
            print(name)
        return 0
    if cmd == "report":        # report <logdir>
        json.dump(read_report(args[0]), sys.stdout)
        print()
        return 0
    if cmd == "status":        # status <out> <plan.json> <mode> <phase> <message> <loader-version> [logdir]
        out, plan_path, mode, phase, message, version = args[:6]
        try:
            with open(plan_path) as f:
                plan = json.load(f)
        except (OSError, ValueError):
            plan = {}
        report = read_report(args[6]) if len(args) > 6 and args[6] else None
        write_status(out, plan, mode, phase, message, {"name": "EML", "version": version}, report)
        return 0
    if cmd == "field":         # field <json file> <key>: one top-level value, for bash
        try:
            with open(args[0]) as f:
                value = json.load(f).get(args[1], "")
        except (OSError, ValueError):
            value = ""
        print(value if not isinstance(value, (list, dict)) else json.dumps(value))
        return 0
    print(f"unknown command {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
