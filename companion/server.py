#!/usr/bin/env python3

from __future__ import annotations

import atexit
import errno
import json
import os
import platform
import plistlib
import re
import secrets
import shutil
import socket
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parent
CACHE = ROOT / "cache"
BIN = ROOT / "bin"
TOKEN_FILE = ROOT / "token.txt"
PORT = 8765

_helper: Path | None = None
_helper_checked = False
_export_slots = threading.Semaphore(2)
_icon_locks_guard = threading.Lock()
_icon_locks: dict[str, threading.Lock] = {}


@dataclass(frozen=True)
class AppEntry:
    id: str
    name: str
    path: str


class Catalog:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._apps: list[AppEntry] = []
        self._by_id: dict[str, AppEntry] = {}
        self._at = 0.0

    def apps(self, force: bool = False) -> list[AppEntry]:
        with self._lock:
            stale = not self._apps or time.time() - self._at > 20
            if force or stale:
                found = scan_apps()
                self._apps = found
                self._by_id = {app.id: app for app in found}
                self._at = time.time()
            return list(self._apps)

    def find(self, app_id: str) -> AppEntry | None:
        with self._lock:
            fresh = bool(self._apps) and time.time() - self._at <= 20
            if fresh:
                return self._by_id.get(app_id)
        self.apps(force=True)
        with self._lock:
            return self._by_id.get(app_id)


CATALOG = Catalog()
TOKEN = ""
_advertiser: subprocess.Popen[bytes] | None = None


def load_token() -> str:
    if TOKEN_FILE.exists():
        token = TOKEN_FILE.read_text(encoding="utf-8").strip().upper()
        if re.fullmatch(r"[A-Z0-9]{6}", token):
            return token
    token = secrets.token_hex(3).upper()
    TOKEN_FILE.write_text(token + "\n", encoding="utf-8")
    try:
        os.chmod(TOKEN_FILE, 0o600)
    except OSError:
        pass
    return token


def local_ips() -> list[str]:
    found: list[str] = []
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if not ip.startswith("127."):
                found.append(ip)
    except OSError:
        pass
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("8.8.8.8", 80))
            found.append(sock.getsockname()[0])
    except OSError:
        pass
    unique: list[str] = []
    for ip in found:
        if ip not in unique:
            unique.append(ip)
    return unique


def ensure_helper() -> Path | None:
    global _helper, _helper_checked
    if _helper_checked:
        return _helper
    _helper_checked = True
    if platform.system() != "Darwin":
        return None
    source = ROOT / "export_icon.swift"
    binary = BIN / "export-icon"
    if not source.exists():
        return None
    if binary.exists() and binary.stat().st_mtime >= source.stat().st_mtime:
        _helper = binary
        return binary
    BIN.mkdir(parents=True, exist_ok=True)
    if shutil.which("xcrun"):
        cmd = ["xcrun", "swiftc", "-O", "-o", str(binary), str(source)]
    elif shutil.which("swiftc"):
        cmd = ["swiftc", "-O", "-o", str(binary), str(source)]
    else:
        print("swiftc não encontrado. Os ícones vão usar o formato .icns quando existir.")
        return None
    print("Compilando leitor de ícones do macOS…")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0 or not binary.exists():
        sys.stderr.write(result.stderr)
        print("Não compilei o leitor de ícones. Vou usar a leitura direta.")
        return None
    _helper = binary
    return binary


def scan_apps() -> list[AppEntry]:
    system = platform.system()
    if system == "Darwin":
        return scan_mac()
    if system == "Windows":
        return scan_windows()
    if system == "Linux":
        return scan_linux()
    return []


def scan_mac() -> list[AppEntry]:
    helper = ensure_helper()
    if helper:
        try:
            result = subprocess.run([str(helper), "list"], capture_output=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired) as exc:
            print(f"Falha ao listar apps: {exc}")
            result = None
        if result is not None and result.returncode == 0 and result.stdout:
            try:
                payload = json.loads(result.stdout.decode("utf-8"))
                apps = []
                for item in payload:
                    app_id = str(item.get("id") or "")
                    name = str(item.get("name") or "")
                    path = str(item.get("path") or "")
                    if app_id and name and path:
                        apps.append(AppEntry(app_id, name, path))
                if apps:
                    return apps
            except json.JSONDecodeError:
                sys.stderr.write(result.stderr.decode("utf-8", "replace"))
        elif result is not None and result.stderr:
            sys.stderr.write(result.stderr.decode("utf-8", "replace"))
    print("Usando leitura direta dos aplicativos.")
    return scan_mac_python()


def iter_app_bundles(root: Path, depth: int):
    if depth > 3 or not root.is_dir():
        return
    try:
        children = list(root.iterdir())
    except OSError:
        return
    for child in children:
        if child.name.startswith("."):
            continue
        try:
            if child.suffix == ".app" and child.is_dir():
                yield child
                continue
            if child.is_dir() and not child.is_symlink() and depth < 3:
                yield from iter_app_bundles(child, depth + 1)
        except OSError:
            continue


def read_mac_app(path: Path) -> AppEntry | None:
    plist_path = path / "Contents" / "Info.plist"
    if not plist_path.is_file():
        return None
    try:
        with plist_path.open("rb") as handle:
            info = plistlib.load(handle)
    except Exception:
        return None
    if not isinstance(info, dict):
        return None
    if info.get("LSBackgroundOnly") is True:
        return None
    kind = info.get("CFBundlePackageType")
    if isinstance(kind, str) and kind not in ("APPL", "FNDR"):
        return None
    bundle_id = info.get("CFBundleIdentifier")
    if not isinstance(bundle_id, str) or not bundle_id:
        return None
    name = info.get("CFBundleDisplayName") or info.get("CFBundleName") or path.stem
    if not isinstance(name, str) or not name.strip():
        name = path.stem
    return AppEntry(bundle_id, name.strip(), str(path))


def scan_mac_python() -> list[AppEntry]:
    roots = [
        (Path("/Applications"), 0),
        (Path.home() / "Applications", 0),
        (Path("/System/Applications"), 1),
    ]
    found: dict[str, tuple[AppEntry, int]] = {}
    finder = read_mac_app(Path("/System/Library/CoreServices/Finder.app"))
    if finder is not None:
        found[finder.id] = (finder, 0)
    for root, priority in roots:
        if not root.exists():
            continue
        for bundle in iter_app_bundles(root, 0):
            entry = read_mac_app(bundle)
            if entry is None:
                continue
            current = found.get(entry.id)
            if current is None or priority < current[1]:
                found[entry.id] = (entry, priority)
    return sorted((item[0] for item in found.values()), key=lambda app: app.name.casefold())


def _reg_str(key, name: str) -> str:
    import winreg

    try:
        value, _ = winreg.QueryValueEx(key, name)
    except OSError:
        return ""
    return str(value).strip() if value else ""


def _windows_target(icon: str, location: str) -> str:
    if icon:
        cleaned = icon.split(",")[0].strip().strip('"')
        if cleaned and os.path.exists(cleaned):
            return cleaned
    if location and os.path.isdir(location):
        return location
    return ""


def scan_windows() -> list[AppEntry]:
    import winreg

    roots = [
        (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"),
        (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"),
        (winreg.HKEY_CURRENT_USER, r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"),
    ]
    found: dict[str, AppEntry] = {}
    for hive, path in roots:
        try:
            root = winreg.OpenKey(hive, path)
        except OSError:
            continue
        try:
            count = winreg.QueryInfoKey(root)[0]
            for index in range(count):
                try:
                    subname = winreg.EnumKey(root, index)
                    sub = winreg.OpenKey(root, subname)
                except OSError:
                    continue
                try:
                    name = _reg_str(sub, "DisplayName")
                    system_component = _reg_str(sub, "SystemComponent")
                    if not name or system_component == "1":
                        continue
                    target = _windows_target(_reg_str(sub, "DisplayIcon"), _reg_str(sub, "InstallLocation"))
                    if not target:
                        continue
                    found.setdefault(name.casefold(), AppEntry(subname, name, target))
                finally:
                    winreg.CloseKey(sub)
        finally:
            winreg.CloseKey(root)
    return sorted(found.values(), key=lambda app: app.name.casefold())


def _desktop_value(text: str, key: str) -> str:
    prefix = key + "="
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith(prefix):
            return stripped[len(prefix) :].strip()
    return ""


def scan_linux() -> list[AppEntry]:
    folders = [
        Path("/usr/share/applications"),
        Path.home() / ".local/share/applications",
        Path("/var/lib/flatpak/exports/share/applications"),
        Path.home() / ".local/share/flatpak/exports/share/applications",
    ]
    found: dict[str, AppEntry] = {}
    for folder in folders:
        if not folder.is_dir():
            continue
        try:
            files = list(folder.glob("*.desktop"))
        except OSError:
            continue
        for file in files:
            try:
                text = file.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            if _desktop_value(text, "NoDisplay") == "true":
                continue
            if _desktop_value(text, "Hidden") == "true":
                continue
            name = (
                _desktop_value(text, "Name[pt_BR]")
                or _desktop_value(text, "Name[pt]")
                or _desktop_value(text, "Name")
            )
            if not name or name.casefold() in found:
                continue
            found[name.casefold()] = AppEntry(file.stem, name, str(file))
    return sorted(found.values(), key=lambda app: app.name.casefold())


CUSTOM = ROOT / "custom-icons"
PHONE_DECK = ROOT / "phone-deck.json"
PHONE_ICONS = ROOT / "phone-icons"
_deck_lock = threading.Lock()


def safe_id(app_id: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "_", app_id)[:180]


def safe_icon_path(app_id: str) -> Path:
    return CACHE / f"{safe_id(app_id)}.png"


def custom_icon_path(app_id: str) -> Path:
    return CUSTOM / f"{safe_id(app_id)}.png"


def valid_key(raw: object) -> str | None:
    if not isinstance(raw, str):
        return None
    if re.fullmatch(r"[A-Za-z0-9._-]{1,80}", raw):
        return raw
    return None


def phone_icon_path(key: str) -> Path:
    return PHONE_ICONS / f"{safe_id(key)}.png"


def empty_phone_deck() -> dict:
    return {"revision": 0, "updated": 0, "slots": [], "links": []}


def load_phone_deck() -> dict:
    if not PHONE_DECK.exists():
        return empty_phone_deck()
    try:
        data = json.loads(PHONE_DECK.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return empty_phone_deck()
    if not isinstance(data, dict):
        return empty_phone_deck()
    return data


def normalize_shortcuts(raw: object, kind: str) -> list[dict]:
    items: list[dict] = []
    if isinstance(raw, list):
        for item in raw[:10]:
            if not isinstance(item, dict):
                continue
            key = valid_key(item.get("key")) or secrets.token_hex(8)
            custom = bool(item.get("custom"))
            if kind == "app":
                items.append({
                    "key": key,
                    "id": str(item.get("id") or "")[:300],
                    "name": str(item.get("name") or "")[:120],
                    "custom": custom,
                })
            else:
                url = safe_web_url(item.get("url")) or ""
                items.append({
                    "key": key,
                    "title": str(item.get("title") or "")[:120],
                    "url": url,
                    "custom": custom,
                })
    while len(items) < 10:
        blank = {"key": secrets.token_hex(8), "custom": False}
        if kind == "app":
            blank["id"] = ""
            blank["name"] = ""
        else:
            blank["title"] = ""
            blank["url"] = ""
        items.append(blank)
    return items[:10]


def write_phone_deck(payload: dict, base: int) -> tuple[dict, int]:
    with _deck_lock:
        current = load_phone_deck()
        current_revision = int(current.get("revision") or 0)
        if base != current_revision:
            return current, 409
        slots = normalize_shortcuts(payload.get("slots"), "app")
        links = normalize_shortcuts(payload.get("links"), "link")
        for slot in slots + links:
            if not slot.get("custom"):
                phone_icon_path(str(slot["key"])).unlink(missing_ok=True)
        document = {
            "revision": current_revision + 1,
            "updated": time.time(),
            "slots": slots,
            "links": links,
        }
        PHONE_DECK.parent.mkdir(parents=True, exist_ok=True)
        tmp = PHONE_DECK.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(document, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(PHONE_DECK)
        return document, 200


def icon_stamp() -> int:
    if not CUSTOM.exists():
        return 0
    newest = 0
    for file in CUSTOM.glob("*.png"):
        try:
            newest = max(newest, int(file.stat().st_mtime))
        except OSError:
            continue
    return newest


def is_png(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            return handle.read(8) == b"\x89PNG\r\n\x1a\n" and path.stat().st_size > 32
    except OSError:
        return False


def icon_lock(app_id: str) -> threading.Lock:
    with _icon_locks_guard:
        lock = _icon_locks.get(app_id)
        if lock is None:
            lock = threading.Lock()
            _icon_locks[app_id] = lock
        return lock


def find_icns(app_path: str) -> Path | None:
    resources = Path(app_path) / "Contents" / "Resources"
    plist_path = Path(app_path) / "Contents" / "Info.plist"
    icon_name = ""
    if plist_path.is_file():
        try:
            with plist_path.open("rb") as handle:
                info = plistlib.load(handle)
            raw = info.get("CFBundleIconFile") or info.get("CFBundleIconName") or ""
            if isinstance(raw, str):
                icon_name = raw
        except Exception:
            icon_name = ""
    if icon_name:
        candidate = resources / (icon_name if icon_name.endswith(".icns") else icon_name + ".icns")
        if candidate.is_file():
            return candidate
    if resources.is_dir():
        try:
            for child in resources.iterdir():
                if child.suffix == ".icns":
                    return child
        except OSError:
            return None
    return None


def export_with_sips(app_path: str, dest: Path) -> bool:
    icns = find_icns(app_path)
    if icns is None or shutil.which("sips") is None:
        return False
    tmp = dest.with_suffix(".sips.png")
    result = subprocess.run(
        ["sips", "-s", "format", "png", str(icns), "--out", str(tmp), "-Z", "512"],
        capture_output=True,
    )
    if result.returncode == 0 and is_png(tmp):
        tmp.replace(dest)
        return True
    tmp.unlink(missing_ok=True)
    return False


def export_with_powershell(source: str, dest: Path) -> bool:
    target = source.split(",")[0].strip().strip('"')
    script = (
        "Add-Type -AssemblyName System.Drawing; "
        "$icon = [System.Drawing.Icon]::ExtractAssociatedIcon($env:DECK_SRC); "
        "if (-not $icon) { exit 1 }; "
        "$bmp = $icon.ToBitmap(); "
        "$bmp.Save($env:DECK_DST, [System.Drawing.Imaging.ImageFormat]::Png)"
    )
    env = os.environ.copy()
    env["DECK_SRC"] = target
    env["DECK_DST"] = str(dest)
    result = subprocess.run(
        ["powershell", "-NoProfile", "-Command", script],
        capture_output=True,
        env=env,
    )
    return result.returncode == 0 and is_png(dest)


def resolve_linux_icon(desktop_path: str) -> Path | None:
    try:
        text = Path(desktop_path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    icon = _desktop_value(text, "Icon")
    if not icon:
        return None
    candidate = Path(icon)
    if candidate.is_file() and candidate.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp"}:
        return candidate
    search = [
        Path("/usr/share/icons/hicolor/512x512/apps"),
        Path("/usr/share/icons/hicolor/256x256/apps"),
        Path("/usr/share/pixmaps"),
        Path.home() / ".local/share/icons/hicolor/256x256/apps",
    ]
    for folder in search:
        for suffix in (".png", ".jpg", ".jpeg"):
            file = folder / f"{icon}{suffix}"
            if file.is_file():
                return file
    return None


def export_icon(app: AppEntry, dest: Path) -> bool:
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(".png.tmp")
    system = platform.system()
    try:
        if system == "Darwin":
            helper = ensure_helper()
            if helper:
                with _export_slots:
                    result = subprocess.run(
                        [str(helper), "icon", app.path, str(tmp)],
                        capture_output=True,
                    )
                if result.returncode == 0 and is_png(tmp):
                    tmp.replace(dest)
                    return True
            return export_with_sips(app.path, dest)
        if system == "Windows":
            return export_with_powershell(app.path, dest)
        source = resolve_linux_icon(app.path)
        if source is None:
            return False
        if source.suffix.lower() == ".png":
            shutil.copyfile(source, dest)
            return is_png(dest)
        if shutil.which("convert"):
            result = subprocess.run(["convert", str(source), str(dest)], capture_output=True)
            return result.returncode == 0 and is_png(dest)
        return False
    finally:
        tmp.unlink(missing_ok=True)


def ensure_icon(app: AppEntry) -> Path | None:
    custom = custom_icon_path(app.id)
    if is_png(custom):
        return custom
    dest = safe_icon_path(app.id)
    if is_png(dest):
        return dest
    with icon_lock(app.id):
        if is_png(dest):
            return dest
        if export_icon(app, dest) and is_png(dest):
            return dest
        dest.unlink(missing_ok=True)
        return None


def safe_web_url(raw: object) -> str | None:
    if not isinstance(raw, str):
        return None
    text = raw.strip()
    if not text or len(text) > 2048:
        return None
    if any(ord(char) < 32 or ord(char) == 127 for char in text):
        return None
    parsed = urlparse(text)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        return None
    return text


def open_url(url: str) -> None:
    system = platform.system()
    if system == "Darwin":
        subprocess.run(["open", url], check=True, timeout=20)
        return
    if system == "Windows":
        os.startfile(url)  # type: ignore[attr-defined]
        return
    subprocess.run(["xdg-open", url], check=True, timeout=20)


def open_app(app: AppEntry) -> None:
    system = platform.system()
    if system == "Darwin":
        subprocess.run(["open", app.path], check=True, timeout=20)
        return
    if system == "Windows":
        os.startfile(app.path)  # type: ignore[attr-defined]
        return
    if shutil.which("gio"):
        subprocess.run(["gio", "launch", app.path], check=True, timeout=20)
        return
    subprocess.run(["gtk-launch", Path(app.path).stem], check=True, timeout=20)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        try:
            message = fmt % args
        except Exception:
            message = str(args)
        if "/api/icons/" in message and "200" in message:
            return
        print(message)

    def _authorized(self) -> bool:
        got = (self.headers.get("X-Deck-Token") or "").strip().upper()
        if len(got) == len(TOKEN) and secrets.compare_digest(got, TOKEN):
            return True
        self._send_json({"ok": False, "error": "Código incorreto."}, 401)
        return False

    def _send_json(self, payload: dict, status: int = 200) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def _send_bytes(self, data: bytes, content_type: str, cache: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", cache)
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def _path(self) -> str:
        return unquote(urlparse(self.path).path)

    def do_GET(self) -> None:  # noqa: N802
        path = self._path()
        if path == "/":
            body = (
                "<!doctype html><meta charset=utf-8><title>Deck</title>"
                "<body style='font-family:sans-serif;background:#111;color:#eee;padding:32px'>"
                "<h1>Deck companion ativo</h1>"
                "<p>Abra o app Deck no celular, na mesma rede Wi-Fi, e informe o endereço e o código mostrados no app Deck do Mac.</p>"
                f"<p>Notebook: {socket.gethostname()}</p></body>"
            ).encode("utf-8")
            self._send_bytes(body, "text/html; charset=utf-8", "no-store")
            return
        if not self._authorized():
            return
        if path == "/api/health":
            apps = CATALOG.apps()
            self._send_json(
                {
                    "ok": True,
                    "hostname": socket.gethostname(),
                    "platform": platform.system(),
                    "apps": len(apps),
                    "iconStamp": icon_stamp(),
                }
            )
            return
        if path == "/api/deck":
            self._send_json(load_phone_deck())
            return
        if path.startswith("/api/phone-icon/"):
            self._read_phone_icon()
            return
        if path == "/api/apps":
            apps = [
                {
                    "id": app.id,
                    "name": app.name,
                    "replaced": is_png(custom_icon_path(app.id)),
                }
                for app in CATALOG.apps()
            ]
            data = json.dumps(apps, ensure_ascii=False).encode("utf-8")
            self._send_bytes(data, "application/json; charset=utf-8", "no-store")
            return
        if path.startswith("/api/icons/"):
            app_id = path[len("/api/icons/") :]
            if not app_id or "/" in app_id or ".." in app_id:
                self._send_json({"ok": False, "error": "Ícone inválido."}, 400)
                return
            app = CATALOG.find(app_id)
            if app is None:
                self._send_json({"ok": False, "error": "App não encontrado."}, 404)
                return
            icon = ensure_icon(app)
            if icon is None:
                self._send_json({"ok": False, "error": "Sem ícone."}, 404)
                return
            cache = "no-store" if is_png(custom_icon_path(app.id)) else "public, max-age=86400"
            self._send_bytes(icon.read_bytes(), "image/png", cache)
            return
        self._send_json({"ok": False, "error": "Não encontrado."}, 404)

    def _read_json(self) -> dict | None:
        try:
            length = int(self.headers.get("Content-Length", "0") or 0)
        except ValueError:
            length = 0
        if length < 0 or length > 8192:
            return None
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None
        return payload if isinstance(payload, dict) else None

    def do_POST(self) -> None:  # noqa: N802
        if not self._authorized():
            return
        path = self._path()
        if path == "/api/launch":
            self._launch_app()
            return
        if path == "/api/open-url":
            self._open_browser()
            return
        if path.startswith("/api/custom-icon/"):
            self._save_custom_icon()
            return
        if path == "/api/deck":
            self._save_phone_deck()
            return
        if path.startswith("/api/phone-icon/"):
            self._save_phone_icon()
            return
        self._send_json({"ok": False, "error": "Não encontrado."}, 404)

    def do_DELETE(self) -> None:  # noqa: N802
        if not self._authorized():
            return
        path = self._path()
        if path.startswith("/api/custom-icon/"):
            self._delete_custom_icon()
            return
        self._send_json({"ok": False, "error": "Não encontrado."}, 404)

    def _phone_icon_key(self) -> str | None:
        return valid_key(self._path()[len("/api/phone-icon/") :])

    def _read_phone_icon(self) -> None:
        key = self._phone_icon_key()
        if key is None:
            self._send_json({"ok": False, "error": "Ícone inválido."}, 400)
            return
        path = phone_icon_path(key)
        if not is_png(path):
            self._send_json({"ok": False, "error": "Sem ícone."}, 404)
            return
        self._send_bytes(path.read_bytes(), "image/png", "no-store")

    def _save_phone_icon(self) -> None:
        key = self._phone_icon_key()
        if key is None:
            self._send_json({"ok": False, "error": "Ícone inválido."}, 400)
            return
        data = self._read_body(1_500_000)
        if data is None or not data.startswith(b"\x89PNG\r\n\x1a\n"):
            self._send_json({"ok": False, "error": "Envie um PNG."}, 400)
            return
        dest = phone_icon_path(key)
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_suffix(".png.tmp")
        tmp.write_bytes(data)
        tmp.replace(dest)
        self._send_json({"ok": True})

    def _save_phone_deck(self) -> None:
        try:
            length = int(self.headers.get("Content-Length", "0") or 0)
        except ValueError:
            length = 0
        if length < 0 or length > 100_000:
            self._send_json({"ok": False, "error": "Pedido inválido."}, 400)
            return
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._send_json({"ok": False, "error": "Pedido inválido."}, 400)
            return
        if not isinstance(payload, dict):
            self._send_json({"ok": False, "error": "Pedido inválido."}, 400)
            return
        try:
            base = int(payload.get("base"))
        except (TypeError, ValueError):
            self._send_json({"ok": False, "error": "Pedido inválido."}, 400)
            return
        document, status = write_phone_deck(payload, base)
        if status == 409:
            document = dict(document)
            document["ok"] = False
            document["error"] = "O deck mudou."
            self._send_json(document, 409)
            return
        document = dict(document)
        document["ok"] = True
        self._send_json(document)

    def _read_body(self, limit: int) -> bytes | None:
        try:
            length = int(self.headers.get("Content-Length", "0") or 0)
        except ValueError:
            return None
        if length <= 0 or length > limit:
            return None
        return self.rfile.read(length)

    def _save_custom_icon(self) -> None:
        app_id = self._path()[len("/api/custom-icon/") :]
        if not app_id or "/" in app_id or ".." in app_id:
            self._send_json({"ok": False, "error": "Ícone inválido."}, 400)
            return
        if CATALOG.find(app_id) is None:
            self._send_json({"ok": False, "error": "App não encontrado no notebook."}, 404)
            return
        data = self._read_body(1_500_000)
        if data is None or not data.startswith(b"\x89PNG\r\n\x1a\n"):
            self._send_json({"ok": False, "error": "Envie um PNG."}, 400)
            return
        dest = custom_icon_path(app_id)
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_suffix(".png.tmp")
        tmp.write_bytes(data)
        tmp.replace(dest)
        safe_icon_path(app_id).unlink(missing_ok=True)
        self._send_json({"ok": True, "iconStamp": icon_stamp()})

    def _delete_custom_icon(self) -> None:
        app_id = self._path()[len("/api/custom-icon/") :]
        if not app_id or "/" in app_id or ".." in app_id:
            self._send_json({"ok": False, "error": "Ícone inválido."}, 400)
            return
        if CATALOG.find(app_id) is None:
            self._send_json({"ok": False, "error": "App não encontrado no notebook."}, 404)
            return
        custom_icon_path(app_id).unlink(missing_ok=True)
        safe_icon_path(app_id).unlink(missing_ok=True)
        self._send_json({"ok": True, "iconStamp": icon_stamp()})

    def _launch_app(self) -> None:
        payload = self._read_json()
        if payload is None:
            self._send_json({"ok": False, "error": "Pedido inválido."}, 400)
            return
        app_id = str(payload.get("id") or "")
        app = CATALOG.find(app_id)
        if app is None or not os.path.exists(app.path):
            self._send_json({"ok": False, "error": "App não encontrado no notebook."}, 404)
            return
        try:
            open_app(app)
        except Exception as exc:
            print(f"Falha ao abrir {app.name}: {exc}")
            self._send_json({"ok": False, "error": "O notebook não conseguiu abrir esse app."}, 500)
            return
        print(f"Abrindo {app.name}")
        self._send_json({"ok": True, "name": app.name})

    def _open_browser(self) -> None:
        payload = self._read_json()
        if payload is None:
            self._send_json({"ok": False, "error": "Pedido inválido."}, 400)
            return
        url = safe_web_url(payload.get("url"))
        if url is None:
            self._send_json({"ok": False, "error": "Esse link não pode ser aberto no notebook."}, 400)
            return
        try:
            open_url(url)
        except Exception as exc:
            print(f"Falha ao abrir link: {exc}")
            self._send_json({"ok": False, "error": "O notebook não conseguiu abrir esse link."}, 500)
            return
        print("Abrindo link no navegador")
        self._send_json({"ok": True})


class DeckServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def print_banner(port: int, ips: list[str]) -> None:
    lines = [
        "",
        "=" * 46,
        "  Deck — companion do notebook",
        f"  Notebook: {socket.gethostname()}",
        "  No celular, informe:",
    ]
    if ips:
        lines.extend(f"  Endereço: {ip}:{port}" for ip in ips)
    else:
        lines.append("  Nenhum IP de rede encontrado.")
        lines.append("  Conecte o notebook ao Wi-Fi e rode de novo.")
    lines.extend([
        f"  Código:   {TOKEN}",
        "  Pelo app Deck no Mac, esta conexão fica em segundo plano.",
        "=" * 46,
        "",
    ])
    print("\n".join(lines), flush=True)


def computer_name() -> str:
    if platform.system() == "Darwin" and shutil.which("scutil"):
        try:
            name = subprocess.check_output(
                ["scutil", "--get", "ComputerName"],
                text=True,
                timeout=2,
            ).strip()
            if name:
                return name.replace(".", " ")[:63]
        except (OSError, subprocess.TimeoutExpired):
            pass
    return socket.gethostname().split(".")[0][:63] or "Deck"


def start_advertiser(port: int) -> None:
    global _advertiser
    if platform.system() != "Darwin" or shutil.which("dns-sd") is None:
        return
    stop_advertiser()
    _advertiser = subprocess.Popen(
        ["dns-sd", "-R", computer_name(), "_deck._tcp", "local", str(port)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def stop_advertiser() -> None:
    global _advertiser
    if _advertiser is None:
        return
    _advertiser.terminate()
    try:
        _advertiser.wait(timeout=2)
    except subprocess.TimeoutExpired:
        _advertiser.kill()
    _advertiser = None


def main() -> None:
    global TOKEN
    port = PORT
    args = sys.argv[1:]
    if "--port" in args:
        index = args.index("--port")
        try:
            port = int(args[index + 1])
        except (IndexError, ValueError):
            print("Use: python3 server.py --port 8765")
            sys.exit(1)
    TOKEN = load_token()
    CACHE.mkdir(parents=True, exist_ok=True)
    ensure_helper()
    apps = CATALOG.apps()
    print(f"Apps encontrados: {len(apps)}")
    try:
        server = DeckServer(("0.0.0.0", port), Handler)
    except OSError as exc:
        print(f"Não consegui abrir a porta {port}: {exc}")
        sys.exit(0 if exc.errno == errno.EADDRINUSE else 1)
    print_banner(port, local_ips())
    start_advertiser(port)
    atexit.register(stop_advertiser)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nCompanion encerrado.")
        server.server_close()
    finally:
        stop_advertiser()


if __name__ == "__main__":
    main()
