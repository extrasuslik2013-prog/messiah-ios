"""Messiah Updater: sends update packs and new IPAs to Messiah 2.0+ on an iPhone,
over Wi-Fi (found automatically with Bonjour) or USB (through Apple's usbmuxd,
installed with iTunes / Apple Devices).

Wire format, both directions: 4-byte big-endian JSON length, 4-byte big-endian
binary length, the JSON, then the binary.
"""
import base64
import json
import os
import plistlib
import queue
import socket
import struct
import sys
import threading
import tkinter as tk
from tkinter import colorchooser, filedialog, messagebox, simpledialog, ttk
from tkinter.scrolledtext import ScrolledText

APP_NAME = "Messiah Updater"
APP_VERSION = "1.1"
PHONE_PORT = 47800
SERVICE = "_messiah-upd._tcp.local."
USBMUX = ("127.0.0.1", 27015)
DATA_DIR = os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "MessiahUpdater")
TOKENS_FILE = os.path.join(DATA_DIR, "tokens.json")
# ownerKey (proves owner rights), ownerUDID (the only iPhone allowed to be owner), inviteSecret (backup)
OWNER_FILE = os.path.join(DATA_DIR, "owner.json")

COLORS = [
    ("magenta", "Magenta (main accent)", "#FF2EC4"),
    ("coral", "Coral", "#FF5C6E"),
    ("amber", "Amber", "#FFC440"),
    ("violet", "Violet (live chat)", "#7D3BFF"),
    ("blue", "Blue (live chat)", "#296BFF"),
]

TEXTS = [
    ("appTitle", "App title (top bar)", "Messiah"),
    ("welcomeText", "Welcome text (empty chat)", "Ask Messiah anything."),
    ("inputPlaceholder", "Message box placeholder", "Message Messiah"),
]

SOUNDS = [
    ("messiah_processing_loop", "Thinking loop"),
    ("messiah_wake", "Live chat opens"),
    ("messiah_window_close", "Live chat closes"),
    ("messiah_mic_on", "Mic on"),
    ("messiah_mic_off", "Mic off"),
    ("messiah_interrupt", "Interrupt / cancel"),
    ("waves_error_ping2", "Error"),
]
SOUND_TYPES = ("wav", "mp3", "m4a", "caf", "aif", "aiff")

# (key, label, choices or None for free text). Empty = leave the phone's value.
SETTINGS = [
    ("provider", "Provider", ["", "ollama", "openrouter"]),
    ("model", "Model", None),
    ("ollamaURL", "Ollama server", None),
    ("appearance", "Appearance", ["", "system", "light", "dark"]),
    ("speechProvider", "Voice", ["", "system", "fish"]),
    ("speechEnabled", "Read answers aloud", ["", "true", "false"]),
]

DEFAULT_PROMPT = (
    "You are Messiah, a practical mobile assistant. Be clear and concise.\n"
    "Never format any response as a table. Always use concise prose or simple headings.\n"
    "Never use emoji characters; if you want to express a feeling, use an occasional "
    "bracketed cue such as [happy], [thinking] or [laughing]."
)

DEFAULT_PERSONALITIES = """Friendly: Warm, upbeat and encouraging. Talks casually, like a supportive friend who is genuinely happy to help.
Witty: Playful and clever, with dry humour and the occasional light tease, but always actually helpful.
Mentor: A patient teacher. Explains the why behind things step by step and checks that I understood.
Blunt: Direct and to the point. Gives the answer first, no fluff, no hedging, no pep talk.
Calm: Soft-spoken and grounding. Slow, reassuring, thoughtful replies that lower the stress level.
Hype: High energy and motivating. Celebrates progress and pushes me to go further."""


# ---------------------------------------------------------------- networking

def recv_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(min(n - len(buf), 1 << 20))
        if not chunk:
            raise ConnectionError("The iPhone closed the connection. Is Messiah open on the phone?")
        buf += chunk
    return bytes(buf)


class PhoneLink:
    def __init__(self, sock):
        self.sock = sock

    def request(self, obj, binary=b"", timeout=30):
        data = json.dumps(obj).encode("utf-8")
        self.sock.settimeout(timeout)
        self.sock.sendall(struct.pack(">II", len(data), len(binary)) + data)
        if binary:
            self.sock.sendall(binary)
        json_len, bin_len = struct.unpack(">II", recv_exact(self.sock, 8))
        reply = json.loads(recv_exact(self.sock, json_len))
        if bin_len:
            recv_exact(self.sock, bin_len)
        return reply

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def _mux_send(sock, payload, tag):
    body = plistlib.dumps(payload)
    sock.sendall(struct.pack("<IIII", 16 + len(body), 1, 8, tag) + body)


def _mux_recv(sock):
    length, _version, _msg, _tag = struct.unpack("<IIII", recv_exact(sock, 16))
    return plistlib.loads(recv_exact(sock, length - 16))


def _mux_open():
    try:
        return socket.create_connection(USBMUX, timeout=4)
    except OSError:
        raise ConnectionError("Apple's USB service is not running. Install iTunes or the Apple Devices app.")


def usb_devices():
    """[(device_id, serial)] for iPhones plugged in by cable."""
    with _mux_open() as s:
        _mux_send(s, {"MessageType": "ListDevices", "ClientVersionString": APP_NAME, "ProgName": APP_NAME}, 1)
        reply = _mux_recv(s)
    out = []
    for d in reply.get("DeviceList", []):
        props = d.get("Properties", {})
        if props.get("ConnectionType") == "USB":
            out.append((d["DeviceID"], props.get("SerialNumber", "?")))
    return out


def usb_connect(device_id, port):
    s = _mux_open()
    _mux_send(s, {"MessageType": "Connect", "DeviceID": device_id, "PortNumber": socket.htons(port),
                  "ClientVersionString": APP_NAME, "ProgName": APP_NAME}, 2)
    reply = _mux_recv(s)
    if reply.get("Number", 1) != 0:
        s.close()
        if reply.get("Number") == 3:
            raise ConnectionError("The iPhone refused the connection. Open Messiah 2.0 on the phone "
                                  "and check Settings > Updater is on.")
        raise ConnectionError(f"USB connection failed (usbmuxd code {reply.get('Number')}). "
                              "Unlock the iPhone and tap Trust if asked.")
    return s


class Discovery:
    """Finds phones advertising the Messiah update service on Wi-Fi."""

    def __init__(self, on_change):
        self.on_change = on_change
        self.devices = {}  # label -> (ip, port)
        self.zc = None

    def start(self):
        try:
            from zeroconf import ServiceBrowser, Zeroconf
            self.zc = Zeroconf()
            self.browser = ServiceBrowser(self.zc, SERVICE, handlers=[self._handler])
        except Exception as e:  # discovery is a convenience; manual IP still works
            self.on_change(error=str(e))

    def _handler(self, zeroconf, service_type, name, state_change):
        threading.Thread(target=self._resolve, args=(zeroconf, service_type, name, str(state_change)),
                         daemon=True).start()

    def _resolve(self, zeroconf, service_type, name, change):
        label = name.replace("." + service_type, "")
        if "Removed" in change:
            self.devices = {k: v for k, v in self.devices.items() if not k.startswith(label)}
        else:
            info = zeroconf.get_service_info(service_type, name, 3000)
            if not info:
                return
            addrs = [a for a in info.parsed_addresses() if ":" not in a]
            if not addrs:
                return
            self.devices = {k: v for k, v in self.devices.items() if not k.startswith(label)}
            self.devices[f"{label}  ({addrs[0]})"] = (addrs[0], info.port or PHONE_PORT)
        self.on_change()

    def close(self):
        if self.zc:
            try:
                self.zc.close()
            except Exception:
                pass


def load_tokens():
    try:
        with open(TOKENS_FILE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_token(device_id, token):
    os.makedirs(DATA_DIR, exist_ok=True)
    tokens = load_tokens()
    tokens[device_id] = token
    with open(TOKENS_FILE, "w", encoding="utf-8") as f:
        json.dump(tokens, f, indent=2)


def load_owner():
    try:
        with open(OWNER_FILE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_owner(data):
    os.makedirs(DATA_DIR, exist_ok=True)
    with open(OWNER_FILE, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)


def resource(name):
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, name)


# ---------------------------------------------------------------- UI

class UpdaterApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(f"{APP_NAME} {APP_VERSION}")
        self.geometry("860x760")
        self.minsize(760, 620)
        try:
            self.iconbitmap(resource("messiah.ico"))
        except tk.TclError:
            pass

        self.ui_queue = queue.Queue()
        self.link = None
        self.target = None  # ("wifi", host, port) or ("usb", device_id, serial)
        self.phone = {}
        self.busy = False
        self.usb_list = []
        self.sound_state = {name: "" for name, _ in SOUNDS}  # "" built-in, "keep", or a file path

        self.discovery = Discovery(lambda error=None: self.post(self._discovery_changed, error))
        self._build()
        self.discovery.start()
        self.after(100, self._drain)
        self.refresh_usb()
        self.protocol("WM_DELETE_WINDOW", self._quit)

    # -- threading helpers

    def post(self, fn, *args):
        self.ui_queue.put((fn, args))

    def _drain(self):
        try:
            while True:
                fn, args = self.ui_queue.get_nowait()
                fn(*args)
        except queue.Empty:
            pass
        self.after(100, self._drain)

    def run_bg(self, label, work, done=None):
        if self.busy:
            messagebox.showinfo(APP_NAME, "Please wait for the current task to finish.")
            return
        self.busy = True
        self.set_status(label + "…")
        self.progress.start(12)

        def runner():
            try:
                result = work()
                self.post(self._bg_done, done, result, None)
            except Exception as e:
                self.post(self._bg_done, done, None, e)

        threading.Thread(target=runner, daemon=True).start()

    def _bg_done(self, done, result, error):
        self.busy = False
        self.progress.stop()
        if error:
            self.log(f"Error: {error}")
            self.set_status(f"Error: {error}")
            messagebox.showerror(APP_NAME, str(error))
        elif done:
            done(result)
        self._update_conn_label()

    # -- layout

    def _build(self):
        style = ttk.Style(self)
        try:
            style.theme_use("vista")
        except tk.TclError:
            pass
        root = ttk.Frame(self, padding=10)
        root.pack(fill="both", expand=True)

        conn = ttk.LabelFrame(root, text="iPhone connection", padding=8)
        conn.pack(fill="x")
        self.mode = tk.StringVar(value="wifi")
        ttk.Radiobutton(conn, text="Wi-Fi", variable=self.mode, value="wifi",
                        command=self._mode_changed).grid(row=0, column=0, sticky="w")
        ttk.Radiobutton(conn, text="USB cable", variable=self.mode, value="usb",
                        command=self._mode_changed).grid(row=0, column=1, sticky="w", padx=(8, 0))
        self.device_box = ttk.Combobox(conn, width=48)
        self.device_box.grid(row=0, column=2, padx=8, sticky="ew")
        ttk.Button(conn, text="Refresh", command=self.refresh_devices).grid(row=0, column=3)
        ttk.Button(conn, text="Connect", command=self.connect).grid(row=0, column=4, padx=(6, 0))
        self.conn_label = ttk.Label(conn, text="Not connected", foreground="#666")
        self.conn_label.grid(row=1, column=0, columnspan=5, sticky="w", pady=(6, 0))
        self.hint_label = ttk.Label(conn, foreground="#888", text="")
        self.hint_label.grid(row=2, column=0, columnspan=5, sticky="w")
        conn.columnconfigure(2, weight=1)
        self._mode_changed()

        nb = ttk.Notebook(root)
        nb.pack(fill="both", expand=True, pady=10)
        nb.add(self._tab_look(nb), text="Look")
        nb.add(self._tab_ai(nb), text="AI & settings")
        nb.add(self._tab_personalities(nb), text="Personalities")
        nb.add(self._tab_sounds(nb), text="Sounds")
        nb.add(self._tab_announce(nb), text="Announcement")
        nb.add(self._tab_ipa(nb), text="Full app update (IPA)")
        nb.add(self._tab_owner(nb), text="Owner")

        bar = ttk.Frame(root)
        bar.pack(fill="x")
        ttk.Label(bar, text="Update name:").pack(side="left")
        self.pack_name = tk.StringVar()
        ttk.Entry(bar, textvariable=self.pack_name, width=22).pack(side="left", padx=(4, 10))
        ttk.Button(bar, text="Push update to iPhone", command=self.push).pack(side="left")
        ttk.Button(bar, text="Pull from iPhone", command=self.pull).pack(side="left", padx=4)
        ttk.Button(bar, text="Reset iPhone to built-in", command=self.reset_phone).pack(side="left")
        ttk.Button(bar, text="Open pack…", command=self.open_pack).pack(side="right")
        ttk.Button(bar, text="Save pack…", command=self.save_pack).pack(side="right", padx=4)

        logf = ttk.LabelFrame(root, text="Log", padding=4)
        logf.pack(fill="both", pady=(10, 0))
        self.log_box = ScrolledText(logf, height=7, state="disabled", font=("Consolas", 9))
        self.log_box.pack(fill="both", expand=True)

        status = ttk.Frame(root)
        status.pack(fill="x", pady=(6, 0))
        self.status = ttk.Label(status, text="Ready")
        self.status.pack(side="left")
        self.progress = ttk.Progressbar(status, mode="indeterminate", length=140)
        self.progress.pack(side="right")

    def _tab_look(self, nb):
        f = ttk.Frame(nb, padding=12)
        ttk.Label(f, text="Colors. Leave a color on Built-in to keep Messiah's default.",
                  foreground="#666").grid(row=0, column=0, columnspan=4, sticky="w", pady=(0, 8))
        self.color_vals = {}
        self.color_swatches = {}
        for i, (key, label, default) in enumerate(COLORS, start=1):
            self.color_vals[key] = ""
            ttk.Label(f, text=label, width=24).grid(row=i, column=0, sticky="w", pady=3)
            sw = tk.Label(f, width=12, relief="groove", cursor="hand2")
            sw.grid(row=i, column=1, padx=6)
            sw.bind("<Button-1>", lambda e, k=key: self.pick_color(k))
            self.color_swatches[key] = sw
            ttk.Button(f, text="Choose…", command=lambda k=key: self.pick_color(k)).grid(row=i, column=2)
            ttk.Button(f, text="Built-in", command=lambda k=key: self.set_color(k, "")).grid(row=i, column=3, padx=4)
            self.set_color(key, "")

        row = len(COLORS) + 1
        ttk.Separator(f).grid(row=row, column=0, columnspan=4, sticky="ew", pady=12)
        ttk.Label(f, text="Text. Leave empty to keep the built-in text.",
                  foreground="#666").grid(row=row + 1, column=0, columnspan=4, sticky="w", pady=(0, 8))
        self.text_vars = {}
        for j, (key, label, default) in enumerate(TEXTS, start=row + 2):
            ttk.Label(f, text=label).grid(row=j, column=0, sticky="w", pady=3)
            var = tk.StringVar()
            self.text_vars[key] = var
            ttk.Entry(f, textvariable=var, width=46).grid(row=j, column=1, columnspan=3, sticky="ew")
            ttk.Label(f, text=f"default: {default}", foreground="#999").grid(row=j, column=4, sticky="w", padx=6)
        return f

    def _tab_ai(self, nb):
        f = ttk.Frame(nb, padding=12)
        head = ttk.Frame(f)
        head.pack(fill="x")
        ttk.Label(head, text="Base system prompt (empty = built-in). The chosen personality is added after it.",
                  foreground="#666").pack(side="left")
        ttk.Button(head, text="Insert built-in prompt",
                   command=lambda: self._set_text(self.prompt_box, DEFAULT_PROMPT)).pack(side="right")
        self.prompt_box = ScrolledText(f, height=9, wrap="word", font=("Segoe UI", 10))
        self.prompt_box.pack(fill="both", expand=True, pady=(6, 10))

        grid = ttk.LabelFrame(f, text="Settings on the phone (empty = don't change)", padding=8)
        grid.pack(fill="x")
        self.setting_vars = {}
        for i, (key, label, choices) in enumerate(SETTINGS):
            ttk.Label(grid, text=label).grid(row=i // 2, column=(i % 2) * 2, sticky="w", padx=(0, 6), pady=3)
            var = tk.StringVar()
            self.setting_vars[key] = var
            if choices:
                w = ttk.Combobox(grid, textvariable=var, values=choices, state="readonly", width=26)
            else:
                w = ttk.Entry(grid, textvariable=var, width=29)
            w.grid(row=i // 2, column=(i % 2) * 2 + 1, sticky="w", padx=(0, 18), pady=3)
        return f

    def _tab_personalities(self, nb):
        f = ttk.Frame(nb, padding=12)
        head = ttk.Frame(f)
        head.pack(fill="x")
        ttk.Label(head, text="One per line as  Name: description.  Empty = keep the built-in list. "
                             "\"Default\" is always added first.", foreground="#666").pack(side="left")
        ttk.Button(head, text="Insert built-in list",
                   command=lambda: self._set_text(self.pers_box, DEFAULT_PERSONALITIES)).pack(side="right")
        self.pers_box = ScrolledText(f, height=14, wrap="word", font=("Segoe UI", 10))
        self.pers_box.pack(fill="both", expand=True, pady=(6, 0))
        return f

    def _tab_sounds(self, nb):
        f = ttk.Frame(nb, padding=12)
        ttk.Label(f, text="Replace any sound effect with your own file (wav, mp3, m4a, caf, aiff; under 15 MB).",
                  foreground="#666").grid(row=0, column=0, columnspan=4, sticky="w", pady=(0, 8))
        self.sound_labels = {}
        for i, (name, label) in enumerate(SOUNDS, start=1):
            ttk.Label(f, text=label, width=20).grid(row=i, column=0, sticky="w", pady=3)
            lbl = ttk.Label(f, width=50, foreground="#444")
            lbl.grid(row=i, column=1, sticky="w")
            self.sound_labels[name] = lbl
            ttk.Button(f, text="Choose…", command=lambda n=name: self.pick_sound(n)).grid(row=i, column=2, padx=4)
            ttk.Button(f, text="Built-in", command=lambda n=name: self.set_sound(n, "")).grid(row=i, column=3)
            self.set_sound(name, "")
        return f

    def _tab_announce(self, nb):
        f = ttk.Frame(nb, padding=12)
        ttk.Label(f, text="Optional message shown once on the iPhone right after this update is applied.",
                  foreground="#666").pack(anchor="w")
        self.announce_box = ScrolledText(f, height=8, wrap="word", font=("Segoe UI", 10))
        self.announce_box.pack(fill="both", expand=True, pady=(6, 0))
        return f

    def _tab_owner(self, nb):
        f = ttk.Frame(nb, padding=12)
        msg = ("Make your own iPhone the owner of Project Messiah (Messiah 2.1+). The owner skips the invite "
               "code and can issue 5-minute invite codes in Messiah > Settings > Admin.\n\n"
               "This only works over a USB cable. The Updater reads the iPhone's serial number (UDID) and only "
               "ever gives owner rights to that one iPhone. The owner key stays on this PC in:\n" + OWNER_FILE +
               "\nBack that file up; don't share it.")
        ttk.Label(f, text=msg, wraplength=760, justify="left").pack(anchor="w")
        self.owner_label = ttk.Label(f, foreground="#333", justify="left")
        self.owner_label.pack(anchor="w", pady=12)
        row = ttk.Frame(f)
        row.pack(anchor="w")
        ttk.Button(row, text="Make connected iPhone the owner", command=self.make_owner).pack(side="left")
        ttk.Button(row, text="Remove owner from connected iPhone", command=self.remove_owner).pack(side="left", padx=6)
        self._update_owner_label()
        return f

    def _update_owner_label(self):
        owner = load_owner()
        lines = [
            "Owner key on this PC: " + ("found" if owner.get("ownerKey") else "MISSING"),
            "Owner iPhone (UDID): " + (owner.get("ownerUDID") or "not set yet (the first iPhone you make owner)"),
        ]
        if self.link and self.phone.get("paired"):
            how = "USB" if self.target[0] == "usb" else "Wi-Fi"
            lines.append(f"Connected iPhone ({how}) is owner: " + ("yes" if self.phone.get("owner") else "no"))
        self.owner_label.configure(text="\n".join(lines))

    def _usb_target_for_owner(self):
        if not self.link or not self.phone.get("paired"):
            messagebox.showwarning(APP_NAME, "Choose USB cable and press Connect first.")
            return None
        if self.target[0] != "usb":
            messagebox.showwarning(APP_NAME, "Owner changes need a USB cable. Choose USB cable and press Connect.")
            return None
        return self.target[2]

    def make_owner(self):
        owner = load_owner()
        if not owner.get("ownerKey"):
            messagebox.showerror(APP_NAME, f"The owner key is missing from {OWNER_FILE}.")
            return
        serial = self._usb_target_for_owner()
        if not serial:
            return
        locked = owner.get("ownerUDID")
        if locked and locked != serial:
            messagebox.showerror(APP_NAME, f"Owner rights are locked to the iPhone with UDID\n{locked}\n\n"
                                           f"The connected iPhone is\n{serial}")
            return
        if not locked and not messagebox.askyesno(
                APP_NAME, f"Lock owner rights to this iPhone?\n\nUDID: {serial}\n\n"
                          "From now on only this iPhone can ever be made owner."):
            return

        def work():
            reply = self._call({"type": "grantOwner", "ownerKey": owner["ownerKey"]})
            self._refresh_info()
            return reply

        def done(_):
            if not locked:
                owner["ownerUDID"] = serial
                save_owner(owner)
            self.log(f"This iPhone ({serial}) is now the owner.")
            self.set_status("Owner set")
            self._update_owner_label()

        self.run_bg("Setting owner", work, done)

    def remove_owner(self):
        if not self._usb_target_for_owner():
            return
        if not messagebox.askyesno(APP_NAME, "Remove owner rights from the connected iPhone?"):
            return

        def work():
            reply = self._call({"type": "revokeOwner"})
            self._refresh_info()
            return reply

        self.run_bg("Removing owner", work, lambda r: self.log("Owner rights removed from the connected iPhone."))

    def _tab_ipa(self, nb):
        f = ttk.Frame(nb, padding=12)
        msg = ("Sends a complete new Messiah IPA to the iPhone. The phone then shows the share sheet: "
               "choose SideStore or AltStore to install it over the current app (your chats are kept).\n\n"
               "Use this for real code changes. Everything on the other tabs updates instantly "
               "without reinstalling.")
        ttk.Label(f, text=msg, wraplength=760, justify="left").pack(anchor="w")
        row = ttk.Frame(f)
        row.pack(fill="x", pady=12)
        self.ipa_path = tk.StringVar()
        ttk.Entry(row, textvariable=self.ipa_path).pack(side="left", fill="x", expand=True)
        ttk.Button(row, text="Choose IPA…", command=self.pick_ipa).pack(side="left", padx=6)
        ttk.Button(f, text="Send IPA to iPhone", command=self.send_ipa).pack(anchor="w")
        return f

    # -- small UI helpers

    def log(self, text):
        self.log_box.configure(state="normal")
        self.log_box.insert("end", text + "\n")
        self.log_box.see("end")
        self.log_box.configure(state="disabled")

    def set_status(self, text):
        self.status.configure(text=text)

    @staticmethod
    def _set_text(box, text):
        box.delete("1.0", "end")
        box.insert("1.0", text)

    @staticmethod
    def _get_text(box):
        return box.get("1.0", "end").strip()

    def set_color(self, key, value):
        self.color_vals[key] = value
        default = next(d for k, _, d in COLORS if k == key)
        sw = self.color_swatches[key]
        shown = value or default
        r, g, b = int(shown[1:3], 16), int(shown[3:5], 16), int(shown[5:7], 16)
        fg = "#000" if (r * 299 + g * 587 + b * 114) / 1000 > 150 else "#fff"
        sw.configure(bg=shown, fg=fg, text=value.upper() if value else "Built-in")

    def pick_color(self, key):
        current = self.color_vals[key] or next(d for k, _, d in COLORS if k == key)
        _, hex_value = colorchooser.askcolor(color=current, title="Choose color", parent=self)
        if hex_value:
            self.set_color(key, hex_value.upper())

    def set_sound(self, name, value):
        self.sound_state[name] = value
        if not value:
            text = "Built-in"
        elif value == "keep":
            text = "Custom sound already on the iPhone"
        else:
            text = os.path.basename(value)
        self.sound_labels[name].configure(text=text)

    def pick_sound(self, name):
        path = filedialog.askopenfilename(parent=self, title="Choose sound",
                                          filetypes=[("Audio", " ".join("*." + t for t in SOUND_TYPES))])
        if path:
            if os.path.getsize(path) >= 15_000_000:
                messagebox.showerror(APP_NAME, "That file is too large (15 MB max).")
                return
            self.set_sound(name, path)

    def pick_ipa(self):
        path = filedialog.askopenfilename(parent=self, title="Choose Messiah IPA",
                                          filetypes=[("iOS app", "*.ipa")])
        if path:
            self.ipa_path.set(path)

    # -- devices

    def _mode_changed(self):
        if self.mode.get() == "wifi":
            self.hint_label.configure(text="Pick the iPhone found on Wi-Fi, or type its address from "
                                           "Messiah > Settings > Updater (e.g. 192.168.1.20).")
            self.device_box.configure(state="normal")
        else:
            self.hint_label.configure(text="Plug the iPhone in, unlock it and tap Trust if asked. "
                                           "Keep Messiah open on the phone.")
            self.device_box.configure(state="readonly")
        self.refresh_devices()

    def refresh_devices(self):
        if self.mode.get() == "wifi":
            self._discovery_changed()
        else:
            self.refresh_usb()

    def _discovery_changed(self, error=None):
        if error:
            self.log(f"Wi-Fi discovery unavailable ({error}). Type the iPhone's address instead.")
        if self.mode.get() != "wifi":
            return
        names = sorted(self.discovery.devices)
        self.device_box.configure(values=names)
        if names and not self.device_box.get():
            self.device_box.set(names[0])

    def refresh_usb(self):
        def work():
            return usb_devices()

        def done(devs):
            self.usb_list = devs
            if self.mode.get() == "usb":
                labels = [f"iPhone on USB  ({serial})" for _, serial in devs]
                self.device_box.configure(values=labels)
                self.device_box.set(labels[0] if labels else "")
                if not labels:
                    self.set_status("No iPhone found on USB")

        def runner():
            try:
                self.post(done, work())
            except Exception as e:
                self.post(done, [])
                msg = str(e)
                self.post(lambda: self.mode.get() == "usb" and self.log(msg))

        threading.Thread(target=runner, daemon=True).start()

    def _selected_target(self):
        text = self.device_box.get().strip()
        if self.mode.get() == "usb":
            labels = [f"iPhone on USB  ({serial})" for _, serial in self.usb_list]
            if text not in labels:
                raise ValueError("No iPhone selected. Plug it in and press Refresh.")
            device_id, serial = self.usb_list[labels.index(text)]
            return ("usb", device_id, serial)
        if not text:
            raise ValueError("Type the iPhone's address or pick it from the list.")
        if text in self.discovery.devices:
            host, port = self.discovery.devices[text]
            return ("wifi", host, port)
        host, _, port = text.partition(":")
        return ("wifi", host.strip(), int(port) if port.strip().isdigit() else PHONE_PORT)

    # -- connection

    def _open(self, target):
        if target[0] == "usb":
            sock = usb_connect(target[1], PHONE_PORT)
        else:
            try:
                sock = socket.create_connection((target[1], target[2]), timeout=6)
            except OSError as e:
                raise ConnectionError(f"Could not reach {target[1]} ({e}). Is Messiah open on the iPhone "
                                      "and on the same Wi-Fi?")
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        link = PhoneLink(sock)
        info = link.request({"type": "hello", "client": APP_NAME})
        token = load_tokens().get(info.get("deviceID", ""))
        if token and not info.get("paired"):
            info = link.request({"type": "hello", "token": token})
        return link, info

    def connect(self):
        try:
            target = self._selected_target()
        except ValueError as e:
            messagebox.showwarning(APP_NAME, str(e))
            return
        if self.link:
            self.link.close()
            self.link = None

        def done(result):
            link, info = result
            self.link, self.target, self.phone = link, target, info
            if not info.get("paired"):
                self.pair()
            else:
                self._connected()

        self.run_bg("Connecting", lambda: self._open(target), done)

    def pair(self):
        code = simpledialog.askstring(APP_NAME, "First time with this iPhone.\n\nOn the phone open "
                                                "Messiah > Settings > Updater and type the 6-digit pairing code:",
                                      parent=self)
        if not code:
            self.log("Pairing cancelled.")
            return
        link = self.link

        def work():
            return link.request({"type": "hello", "code": code.strip()})

        def done(info):
            if info.get("paired") and info.get("token"):
                save_token(info.get("deviceID", ""), info["token"])
                self.phone = info
                self.log("Paired with the iPhone. You won't need the code again on this PC.")
                self._connected()
            else:
                self.log(info.get("error", "Pairing failed."))
                if messagebox.askretrycancel(APP_NAME, (info.get("error") or "Pairing failed") +
                                             ". Check the code on the phone."):
                    self.pair()

        self.run_bg("Pairing", work, done)

    def _connected(self):
        how = "USB" if self.target[0] == "usb" else f"Wi-Fi {self.target[1]}"
        p = self.phone
        self.log(f"Connected over {how}: {p.get('app')} {p.get('version')} ({p.get('build')}), "
                 f"update pack #{p.get('packVersion') or 'none'}.")
        self.set_status("Connected")
        self._update_conn_label()

    def _update_conn_label(self):
        if self.link and self.phone.get("paired"):
            how = "USB" if self.target[0] == "usb" else f"Wi-Fi {self.target[1]}"
            pack = self.phone.get("packVersion") or "none"
            name = self.phone.get("packName") or ""
            self.conn_label.configure(
                text=f"Connected over {how}  ·  Messiah {self.phone.get('version')} "
                     f"({self.phone.get('build')})  ·  update pack: {pack} {name}".rstrip(),
                foreground="#1a7f37")
        else:
            self.conn_label.configure(text="Not connected", foreground="#666")
        self._update_owner_label()

    def _call(self, payload, binary=b"", timeout=30):
        """Runs one request, reconnecting once if the phone dropped the connection."""
        if not self.link:
            raise ConnectionError("Connect to the iPhone first.")
        try:
            reply = self.link.request(payload, binary, timeout)
        except (OSError, ConnectionError, ValueError, struct.error):
            self.link.close()
            link, info = self._open(self.target)
            if not info.get("paired"):
                raise ConnectionError("The iPhone forgot this PC. Press Connect and pair again.")
            self.link, self.phone = link, info
            reply = self.link.request(payload, binary, timeout)
        if reply.get("needsPairing"):
            raise ConnectionError("The iPhone forgot this PC. Press Connect and pair again.")
        if not reply.get("ok"):
            raise RuntimeError(reply.get("error", "The iPhone rejected the request."))
        return reply

    def _refresh_info(self):
        info = self.link.request({"type": "hello", "token": load_tokens().get(self.phone.get("deviceID", ""), "")})
        if info.get("paired"):
            self.phone = info

    # -- packs

    def collect(self):
        """Builds the 'apply' request from the form."""
        cfg = {}
        name = self.pack_name.get().strip()
        if name:
            cfg["packName"] = name
        colors = {k: v for k, v in self.color_vals.items() if v}
        if colors:
            cfg["colors"] = colors
        for key, var in self.text_vars.items():
            if var.get().strip():
                cfg[key] = var.get().strip()
        prompt = self._get_text(self.prompt_box)
        if prompt:
            cfg["baseSystemPrompt"] = prompt
        people = []
        for line in self._get_text(self.pers_box).splitlines():
            if ":" in line:
                n, t = line.split(":", 1)
                if n.strip() and t.strip() and n.strip().lower() != "default":
                    people.append({"name": n.strip(), "text": t.strip()})
            elif line.strip():
                raise ValueError(f"Personality line needs 'Name: description':\n{line}")
        if people:
            cfg["personalities"] = people
        note = self._get_text(self.announce_box)
        if note:
            cfg["announcement"] = note

        uploads, keep = {}, []
        for sname, value in self.sound_state.items():
            if value == "keep":
                keep.append(sname)
            elif value:
                ext = os.path.splitext(value)[1].lower().lstrip(".")
                if ext not in SOUND_TYPES:
                    raise ValueError(f"Unsupported sound type: {value}")
                with open(value, "rb") as f:
                    uploads[sname] = {"ext": ext, "data": base64.b64encode(f.read()).decode("ascii")}
        settings = {k: v.get().strip() for k, v in self.setting_vars.items() if v.get().strip()}
        return {"type": "apply", "config": cfg, "soundUploads": uploads, "keepSounds": keep,
                "settings": settings}

    def push(self):
        try:
            req = self.collect()
        except (ValueError, OSError) as e:
            messagebox.showerror(APP_NAME, str(e))
            return

        def work():
            reply = self._call(req, timeout=120)
            self._refresh_info()
            return reply

        def done(reply):
            self.log(f"Update #{reply.get('packVersion')} applied: " + ", ".join(reply.get("changes", [])))
            self.set_status("Update applied")
            self._set_text(self.announce_box, "")

        self.run_bg("Sending update", work, done)

    def pull(self):
        def done(reply):
            cfg = reply.get("config") or {}
            self.pack_name.set(cfg.get("packName") or "")
            for key in self.color_vals:
                self.set_color(key, (cfg.get("colors") or {}).get(key, "").upper())
            for key, var in self.text_vars.items():
                var.set(cfg.get(key) or "")
            self._set_text(self.prompt_box, cfg.get("baseSystemPrompt") or "")
            self._set_text(self.pers_box, "\n".join(f"{p['name']}: {p['text']}" for p in cfg.get("personalities") or []))
            self._set_text(self.announce_box, "")
            phone_sounds = cfg.get("sounds") or {}
            for name, _ in SOUNDS:
                self.set_sound(name, "keep" if name in phone_sounds else "")
            settings = reply.get("settings") or {}
            for key, var in self.setting_vars.items():
                var.set(settings.get(key, ""))
            self.log("Loaded the iPhone's current update pack and settings.")
            self.set_status("Pulled from iPhone")

        self.run_bg("Reading from iPhone", lambda: self._call({"type": "getConfig"}), done)

    def reset_phone(self):
        if not messagebox.askyesno(APP_NAME, "Remove the update pack from the iPhone and go back to the "
                                             "built-in colors, text, sounds and prompt?"):
            return

        def work():
            reply = self._call({"type": "reset"})
            self._refresh_info()
            return reply

        self.run_bg("Resetting", work, lambda r: self.log("iPhone reset to built-in."))

    def send_ipa(self):
        path = self.ipa_path.get().strip()
        if not path or not os.path.isfile(path):
            messagebox.showwarning(APP_NAME, "Choose an IPA file first.")
            return
        size = os.path.getsize(path) / 1_000_000

        def work():
            with open(path, "rb") as f:
                data = f.read()
            return self._call({"type": "installIPA", "fileName": os.path.basename(path)}, data, timeout=600)

        def done(_):
            self.log(f"Sent {os.path.basename(path)} ({size:.1f} MB). On the iPhone, choose SideStore or "
                     "AltStore in the share sheet to install it.")
            self.set_status("IPA sent")

        self.run_bg(f"Sending IPA ({size:.1f} MB)", work, done)

    def save_pack(self):
        path = filedialog.asksaveasfilename(parent=self, defaultextension=".messiahpack",
                                            filetypes=[("Messiah update pack", "*.messiahpack")])
        if not path:
            return
        data = {
            "packName": self.pack_name.get(),
            "colors": self.color_vals,
            "texts": {k: v.get() for k, v in self.text_vars.items()},
            "prompt": self._get_text(self.prompt_box),
            "personalities": self._get_text(self.pers_box),
            "announcement": self._get_text(self.announce_box),
            "sounds": {k: v for k, v in self.sound_state.items() if v and v != "keep"},
            "settings": {k: v.get() for k, v in self.setting_vars.items()},
        }
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        self.log(f"Saved pack to {path}")

    def open_pack(self):
        path = filedialog.askopenfilename(parent=self, filetypes=[("Messiah update pack", "*.messiahpack")])
        if not path:
            return
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError) as e:
            messagebox.showerror(APP_NAME, f"Could not open pack: {e}")
            return
        self.pack_name.set(data.get("packName", ""))
        for key in self.color_vals:
            self.set_color(key, (data.get("colors") or {}).get(key, ""))
        for key, var in self.text_vars.items():
            var.set((data.get("texts") or {}).get(key, ""))
        self._set_text(self.prompt_box, data.get("prompt", ""))
        self._set_text(self.pers_box, data.get("personalities", ""))
        self._set_text(self.announce_box, data.get("announcement", ""))
        for name, _ in SOUNDS:
            p = (data.get("sounds") or {}).get(name, "")
            self.set_sound(name, p if p and os.path.isfile(p) else "")
        for key, var in self.setting_vars.items():
            var.set((data.get("settings") or {}).get(key, ""))
        self.log(f"Opened pack {path}")

    def _quit(self):
        self.discovery.close()
        if self.link:
            self.link.close()
        self.destroy()


if __name__ == "__main__":
    UpdaterApp().mainloop()
