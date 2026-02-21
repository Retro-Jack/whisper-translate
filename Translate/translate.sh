#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="${SCRIPT_DIR}/whisper-env"

# Check for python3
if ! command -v python3 &>/dev/null; then
  echo "Error: python3 not found. Please install Python 3 first."
  exit 1
fi

# Check for ffmpeg / ffprobe
if ! command -v ffmpeg &>/dev/null; then
  echo "Error: ffmpeg not found. Please install ffmpeg first."
  exit 1
fi
if ! command -v ffprobe &>/dev/null; then
  echo "Error: ffprobe not found. Please install ffmpeg (includes ffprobe)."
  exit 1
fi

# Check for curses (standard library, but can be missing on minimal installs)
if ! python3 -c "import curses" &>/dev/null; then
  echo "Error: Python 'curses' module not available."
  echo "  Arch/CachyOS: sudo pacman -S python"
  echo "  Ubuntu/Debian: sudo apt install python3-curses"
  exit 1
fi

# Set up venv and install whisper if needed
if [ ! -f "${VENV}/bin/whisper" ]; then
  echo "Setting up whisper environment (first run only)..."
  python3 -m venv "${VENV}"
  "${VENV}/bin/pip" install openai-whisper
  echo "Done."
fi

# If a file argument was given, skip the TUI and run directly
if [ -n "$1" ]; then
  INPUT="$1"
  MODEL="${2:-turbo}"
  BASE="${INPUT%.*}"
  trap 'rm -f "${BASE}.wav"' EXIT
  ffmpeg -i "$INPUT" -vn -ac 1 -ar 16000 "${BASE}.wav"
  "${VENV}/bin/whisper" "${BASE}.wav" \
    --model "$MODEL" \
    --task translate \
    --output_format srt
  exit 0
fi

# Launch the TUI — write to a temp file so stdin stays attached to the terminal
TMPPY="$(mktemp /tmp/translate_tui_XXXXXX.py)"
trap 'rm -f "$TMPPY"' EXIT
cat > "$TMPPY" <<'PYTHON_EOF'
import curses
import os
import re
import sys
import subprocess
import threading
import queue

VENV = sys.argv[1]
MODELS = ["tiny", "small", "medium", "large", "turbo"]
MODELS_DISPLAY = [m.capitalize() for m in MODELS]
DEFAULT_MODEL = 4  # turbo
VIDEO_EXTS = {".mp4", ".mkv", ".avi", ".mov", ".wmv", ".flv", ".webm", ".m4v", ".ts", ".mpg", ".mpeg"}
TIME_REGEX = re.compile(r"time=(\d+):(\d+):([\d.]+)")
LANGUAGES = [
    "Afrikaans", "Albanian", "Amharic", "Arabic", "Armenian", "Assamese",
    "Azerbaijani", "Bashkir", "Basque", "Belarusian", "Bengali", "Bosnian",
    "Breton", "Bulgarian", "Cantonese", "Catalan", "Chinese", "Croatian",
    "Czech", "Danish", "Dutch", "English", "Estonian", "Faroese", "Finnish",
    "French", "Galician", "Georgian", "German", "Greek", "Gujarati",
    "Haitian Creole", "Hausa", "Hawaiian", "Hebrew", "Hindi", "Hungarian",
    "Icelandic", "Indonesian", "Italian", "Japanese", "Javanese", "Kannada",
    "Kazakh", "Khmer", "Korean", "Lao", "Latin", "Latvian", "Lingala",
    "Lithuanian", "Luxembourgish", "Macedonian", "Malagasy", "Malay",
    "Malayalam", "Maltese", "Maori", "Marathi", "Mongolian", "Myanmar",
    "Nepali", "Norwegian", "Nynorsk", "Occitan", "Pashto", "Persian",
    "Polish", "Portuguese", "Punjabi", "Romanian", "Russian", "Sanskrit",
    "Serbian", "Shona", "Sindhi", "Sinhala", "Slovak", "Slovenian", "Somali",
    "Spanish", "Sundanese", "Swahili", "Swedish", "Tagalog", "Tajik", "Tamil",
    "Tatar", "Telugu", "Thai", "Tibetan", "Turkish", "Turkmen", "Ukrainian",
    "Urdu", "Uzbek", "Vietnamese", "Welsh", "Yiddish", "Yoruba",
]
LANGUAGE_CODES = {
    "Afrikaans": "af", "Albanian": "sq", "Amharic": "am", "Arabic": "ar",
    "Armenian": "hy", "Assamese": "as", "Azerbaijani": "az", "Bashkir": "ba",
    "Basque": "eu", "Belarusian": "be", "Bengali": "bn", "Bosnian": "bs",
    "Breton": "br", "Bulgarian": "bg", "Cantonese": "yue", "Catalan": "ca",
    "Chinese": "zh", "Croatian": "hr", "Czech": "cs", "Danish": "da",
    "Dutch": "nl", "English": "en", "Estonian": "et", "Faroese": "fo",
    "Finnish": "fi", "French": "fr", "Galician": "gl", "Georgian": "ka",
    "German": "de", "Greek": "el", "Gujarati": "gu", "Haitian Creole": "ht",
    "Hausa": "ha", "Hawaiian": "haw", "Hebrew": "he", "Hindi": "hi",
    "Hungarian": "hu", "Icelandic": "is", "Indonesian": "id", "Italian": "it",
    "Japanese": "ja", "Javanese": "jw", "Kannada": "kn", "Kazakh": "kk",
    "Khmer": "km", "Korean": "ko", "Lao": "lo", "Latin": "la",
    "Latvian": "lv", "Lingala": "ln", "Lithuanian": "lt", "Luxembourgish": "lb",
    "Macedonian": "mk", "Malagasy": "mg", "Malay": "ms", "Malayalam": "ml",
    "Maltese": "mt", "Maori": "mi", "Marathi": "mr", "Mongolian": "mn",
    "Myanmar": "my", "Nepali": "ne", "Norwegian": "no", "Nynorsk": "nn",
    "Occitan": "oc", "Pashto": "ps", "Persian": "fa", "Polish": "pl",
    "Portuguese": "pt", "Punjabi": "pa", "Romanian": "ro", "Russian": "ru",
    "Sanskrit": "sa", "Serbian": "sr", "Shona": "sn", "Sindhi": "sd",
    "Sinhala": "si", "Slovak": "sk", "Slovenian": "sl", "Somali": "so",
    "Spanish": "es", "Sundanese": "su", "Swahili": "sw", "Swedish": "sv",
    "Tagalog": "tl", "Tajik": "tg", "Tamil": "ta", "Tatar": "tt",
    "Telugu": "te", "Thai": "th", "Tibetan": "bo", "Turkish": "tr",
    "Turkmen": "tk", "Ukrainian": "uk", "Urdu": "ur", "Uzbek": "uz",
    "Vietnamese": "vi", "Welsh": "cy", "Yiddish": "yi", "Yoruba": "yo",
}


def draw_border(win, title=""):
    win.border()
    if title:
        h, w = win.getmaxyx()
        label = f" {title} "
        x = max(2, (w - len(label)) // 2)
        try:
            win.addstr(0, x, label, curses.color_pair(1) | curses.A_BOLD)
        except curses.error:
            pass


class FilePicker:
    def __init__(self, stdscr, start_dir):
        self.stdscr = stdscr
        self.directory = os.path.abspath(start_dir)
        self.entries = []
        self.cursor = 0
        self.offset = 0
        self._load()

    def _load(self):
        try:
            raw = os.listdir(self.directory)
        except OSError:
            raw = []
        dirs = sorted([e for e in raw if os.path.isdir(os.path.join(self.directory, e))], key=str.lower)
        files = sorted(
            [e for e in raw if os.path.splitext(e)[1].lower() in VIDEO_EXTS],
            key=str.lower,
        )
        self.entries = [".."] + dirs + files
        self.cursor = 0
        self.offset = 0

    def run(self):
        h, w = self.stdscr.getmaxyx()
        ph, pw = h - 4, w - 4
        win = curses.newwin(ph, pw, 2, 2)
        win.keypad(True)
        focus = "input"  # "list" or "input" — start on path field
        input_text = ""
        input_cur = 0
        input_error = ""
        while True:
            win.erase()
            draw_border(win, "Select Video File")
            iw = pw - 4
            # Layout: border(0), input(1), sep(2), list(3..ph-4), sep(ph-3), footer(ph-2), border(ph-1)
            ih = ph - 6   # list rows 3..(ph-4)

            # Path input row
            input_row = 1
            input_label = "Path: "
            field_w = max(1, iw - len(input_label) - 1)
            vis_start = max(0, input_cur - field_w + 1) if input_text else 0
            vis_text = input_text[vis_start:vis_start + field_w]
            if focus == "input":
                input_attr = curses.color_pair(2) | curses.A_BOLD
            else:
                input_attr = curses.color_pair(5)   # white — always visible
            try:
                win.addstr(input_row, 2, input_label, curses.color_pair(3) | curses.A_BOLD)
                win.addstr(input_row, 2 + len(input_label), vis_text.ljust(field_w), input_attr)
            except curses.error:
                pass
            if input_error:
                try:
                    win.addstr(input_row, 2 + len(input_label) + field_w + 1,
                               input_error, curses.color_pair(1))
                except curses.error:
                    pass

            # Separator below input — directory label embedded in line
            try:
                dir_label = f" {self.directory} "
                sep = (dir_label + "─" * iw)[:iw]
                win.addstr(2, 2, sep, curses.color_pair(3))
            except curses.error:
                pass

            # File list (starts at row 3)
            for i in range(ih):
                idx = self.offset + i
                if idx >= len(self.entries):
                    break
                entry = self.entries[idx]
                full = os.path.join(self.directory, entry)
                is_dir = entry == ".." or os.path.isdir(full)
                label = ("/" + entry) if is_dir else entry
                label = label[:iw]
                attr = curses.color_pair(3) if is_dir else curses.color_pair(5)
                if idx == self.cursor and focus == "list":
                    attr = curses.color_pair(2) | curses.A_BOLD
                try:
                    win.addstr(3 + i, 2, label.ljust(iw), attr)
                except curses.error:
                    pass

            # Separator above footer
            try:
                win.addstr(ph - 3, 2, "─" * iw, curses.color_pair(3))
            except curses.error:
                pass

            # Footer
            if focus == "input":
                hint = " Enter:go  Esc:cancel "
            else:
                hint = " Enter:select  Tab:path  q:cancel "
            try:
                win.addstr(ph - 2, 2, hint, curses.color_pair(5))
            except curses.error:
                pass

            # Hardware cursor — visible only when input focused
            if focus == "input":
                cur_x = 2 + len(input_label) + (input_cur - vis_start)
                try:
                    curses.curs_set(1)
                    win.move(input_row, min(cur_x, pw - 2))
                except curses.error:
                    pass
            else:
                try:
                    curses.curs_set(0)
                except curses.error:
                    pass

            win.refresh()
            key = win.getch()

            if key == curses.KEY_MOUSE:
                try:
                    _, mx, my, _, bstate = curses.getmouse()
                    ry, rx = my - 2, mx - 2
                    scroll_up   = bstate & curses.BUTTON4_PRESSED
                    scroll_down = bstate & getattr(curses, "BUTTON5_PRESSED", 2097152)
                    click       = bstate & (curses.BUTTON1_CLICKED | curses.BUTTON1_PRESSED)
                    dclick      = bstate & curses.BUTTON1_DOUBLE_CLICKED
                    if scroll_up and self.cursor > 0:
                        self.cursor -= 1
                        if self.cursor < self.offset:
                            self.offset = self.cursor
                    elif scroll_down and self.cursor < len(self.entries) - 1:
                        self.cursor += 1
                        if self.cursor >= self.offset + ih:
                            self.offset = self.cursor - ih + 1
                    elif ry == 1 and click:   # input row
                        focus = "input"
                        field_start = 2 + len(input_label)
                        if rx >= field_start:
                            input_cur = min(rx - field_start, len(input_text))
                    elif 3 <= ry <= 2 + ih and (click or dclick):  # list
                        focus = "list"
                        idx = self.offset + (ry - 3)
                        if 0 <= idx < len(self.entries):
                            self.cursor = idx
                            if dclick:
                                entry = self.entries[self.cursor]
                                full = os.path.join(self.directory, entry) if entry != ".." else os.path.dirname(self.directory)
                                if entry == ".." or os.path.isdir(full):
                                    self.directory = os.path.abspath(full)
                                    self._load()
                                else:
                                    curses.curs_set(0)
                                    return full
                except curses.error:
                    pass
            elif focus == "input":
                if key == 27:  # Esc — close picker
                    curses.curs_set(0)
                    return None
                elif key in (curses.KEY_ENTER, 10, 13):
                    target = os.path.abspath(input_text.strip())
                    if os.path.isdir(target):
                        self.directory = target
                        self._load()
                        input_text = ""
                        input_cur = 0
                        input_error = ""
                        focus = "list"
                    elif os.path.isfile(target) and os.path.splitext(target)[1].lower() in VIDEO_EXTS:
                        curses.curs_set(0)
                        return target
                    elif os.path.isfile(target):
                        input_error = "not a video"
                    else:
                        input_error = "not found"
                elif key in (curses.KEY_BACKSPACE, 127):
                    if input_cur > 0:
                        input_text = input_text[:input_cur - 1] + input_text[input_cur:]
                        input_cur -= 1
                    input_error = ""
                elif key in (ord("\t"), curses.KEY_BTAB):
                    focus = "list"
                    self.cursor = 0
                    self.offset = 0
                elif key in (curses.KEY_UP, curses.KEY_DOWN):
                    focus = "list"
                    self.cursor = 0
                    self.offset = 0
                elif key == curses.KEY_LEFT:
                    input_cur = max(0, input_cur - 1)
                    input_error = ""
                elif key == curses.KEY_RIGHT:
                    input_cur = min(len(input_text), input_cur + 1)
                    input_error = ""
                elif key == curses.KEY_HOME:
                    input_cur = 0
                    input_error = ""
                elif key == curses.KEY_END:
                    input_cur = len(input_text)
                    input_error = ""
                elif 32 <= key <= 126:
                    input_text = input_text[:input_cur] + chr(key) + input_text[input_cur:]
                    input_cur += 1
                    input_error = ""
            else:
                if key == curses.KEY_UP and self.cursor == 0:
                    focus = "input"
                elif key == curses.KEY_UP and self.cursor > 0:
                    self.cursor -= 1
                    if self.cursor < self.offset:
                        self.offset = self.cursor
                elif key == curses.KEY_DOWN and self.cursor < len(self.entries) - 1:
                    self.cursor += 1
                    if self.cursor >= self.offset + ih:
                        self.offset = self.cursor - ih + 1
                elif key == curses.KEY_HOME:
                    self.cursor = 0
                    self.offset = 0
                elif key == curses.KEY_END:
                    self.cursor = len(self.entries) - 1
                    self.offset = max(0, self.cursor - ih + 1)
                elif key == curses.KEY_PPAGE:  # Page Up
                    self.cursor = max(0, self.cursor - ih)
                    self.offset = max(0, self.offset - ih)
                elif key == curses.KEY_NPAGE:  # Page Down
                    self.cursor = min(len(self.entries) - 1, self.cursor + ih)
                    self.offset = min(max(0, len(self.entries) - ih), self.offset + ih)
                elif key in (curses.KEY_ENTER, 10, 13):
                    entry = self.entries[self.cursor]
                    full = os.path.join(self.directory, entry) if entry != ".." else os.path.dirname(self.directory)
                    if entry == ".." or os.path.isdir(full):
                        self.directory = os.path.abspath(full)
                        self._load()
                    else:
                        curses.curs_set(0)
                        return full
                elif key in (ord("\t"), curses.KEY_BTAB):
                    focus = "input"
                    input_cur = len(input_text)
                    input_error = ""
                elif key in (27, ord("q")):
                    curses.curs_set(0)
                    return None


def pick_language(stdscr, current):
    """Scrollable language picker. Returns new lang string, None for autodetect, or current on cancel."""
    options = LANGUAGES
    cursor = options.index(current) if current in options else 0
    offset = 0
    h, w = stdscr.getmaxyx()
    ph = min(h - 6, len(options) + 3)
    pw = 30
    py, px = (h - ph) // 2, (w - pw) // 2
    win = curses.newwin(ph, pw, py, px)
    win.keypad(True)
    ih = ph - 2
    while True:
        win.erase()
        draw_border(win, "Language")
        for i in range(ih):
            idx = offset + i
            if idx >= len(options):
                break
            label = options[idx][:pw - 3]
            attr = curses.color_pair(2) | curses.A_BOLD if idx == cursor else curses.color_pair(5)
            try:
                win.addstr(1 + i, 1, label.ljust(pw - 2), attr)
            except curses.error:
                pass
        win.refresh()
        key = win.getch()
        if key == curses.KEY_UP and cursor > 0:
            cursor -= 1
            if cursor < offset:
                offset = cursor
        elif key == curses.KEY_DOWN and cursor < len(options) - 1:
            cursor += 1
            if cursor >= offset + ih:
                offset = cursor - ih + 1
        elif key in (curses.KEY_ENTER, 10, 13):
            return options[cursor]
        elif key == 27:
            return current
        elif key == curses.KEY_MOUSE:
            try:
                _, mx, my, _, bstate = curses.getmouse()
                scroll_up   = bstate & curses.BUTTON4_PRESSED
                scroll_down = bstate & getattr(curses, "BUTTON5_PRESSED", 2097152)
                click       = bstate & (curses.BUTTON1_CLICKED | curses.BUTTON1_PRESSED)
                dclick      = bstate & curses.BUTTON1_DOUBLE_CLICKED
                ry = my - py
                if click and (my < py or my >= py + ph or mx < px or mx >= px + pw):
                    return current
                elif scroll_up and cursor > 0:
                    cursor -= 1
                    if cursor < offset:
                        offset = cursor
                elif scroll_down and cursor < len(options) - 1:
                    cursor += 1
                    if cursor >= offset + ih:
                        offset = cursor - ih + 1
                elif (click or dclick) and 1 <= ry <= ih:
                    idx = offset + (ry - 1)
                    if 0 <= idx < len(options):
                        cursor = idx
                        if dclick:
                            return options[cursor]
            except curses.error:
                pass



def main(stdscr):
    curses.set_escdelay(25)
    curses.mousemask(curses.ALL_MOUSE_EVENTS | curses.REPORT_MOUSE_POSITION)
    curses.curs_set(0)
    curses.start_color()
    curses.use_default_colors()

    # Color pairs — dark mode
    curses.init_pair(1, curses.COLOR_MAGENTA, -1)   # title / accents
    curses.init_pair(2, curses.COLOR_BLACK, curses.COLOR_MAGENTA)  # selected
    curses.init_pair(3, curses.COLOR_BLUE, -1)       # borders / labels / directories
    curses.init_pair(5, curses.COLOR_WHITE, -1)      # files
    curses.init_pair(6, 8, -1)                       # dim hints (dark grey)
    curses.init_pair(7, curses.COLOR_CYAN, -1)       # log output
    curses.init_pair(8, curses.COLOR_GREEN, -1)      # progress bar fill

    selected_file = None
    model_idx = DEFAULT_MODEL
    lang = None       # None = autodetect, string = specific language
    ui_focus = 0      # 0=file button, 1-5=model options, 6=lang auto, 7=lang manual
    log_lines = []
    running = False
    progress = None   # None = hidden, 0.0–1.0 when active
    log_scroll = 0    # lines scrolled up from bottom; 0 = follow tail
    log_q = queue.Queue()  # items: ("log", str) | ("progress", float) | ("done",) | ("cancelled",)
    cancel_event = threading.Event()  # set to request job cancellation
    current_proc = [None]             # currently running subprocess (for termination)
    quit_requested = [False]

    def draw(status="", inactive=False):
        stdscr.erase()
        h, w = stdscr.getmaxyx()

        # Title bar
        title = " Whisper Translate "
        try:
            stdscr.addstr(0, (w - len(title)) // 2, title, curses.color_pair(1) | curses.A_BOLD)
        except curses.error:
            pass

        # File row — "File:" is a static label; the button is the tab stop
        file_inner = os.path.basename(selected_file) if selected_file else "Select"
        file_btn = f"[ {file_inner} ]"
        if not running and ui_focus == 0:
            file_btn_attr = curses.color_pair(1) | curses.A_BOLD
        else:
            file_btn_attr = curses.color_pair(5)
        try:
            stdscr.addstr(2, 2, "File:  ", curses.color_pair(3))
            stdscr.addstr(2, 9, file_btn[: w - 11], file_btn_attr)
        except curses.error:
            pass

        # Brain radio buttons — ◉ follows ui_focus when on model row, otherwise tracks model_idx
        _model_idle = running or ui_focus not in range(1, 6)
        try:
            stdscr.addstr(4, 2, "Brain: ", curses.color_pair(3))
        except curses.error:
            pass
        x = 9
        for i, m in enumerate(MODELS_DISPLAY):
            dot = "◉" if (not running and ui_focus == i + 1) or (_model_idle and i == model_idx) else "○"
            label = f"{dot} {m}  "
            try:
                stdscr.addstr(4, x, label, curses.color_pair(5))
            except curses.error:
                pass
            x += len(label)

        # Language row — ◉/○ follows ui_focus when on lang stops, otherwise lang value
        _lang_idle = running or ui_focus not in (6, 7)
        lang_dot_auto = "◉" if (not running and ui_focus == 6) or (_lang_idle and lang is None) else "○"
        lang_dot_man  = "◉" if (not running and ui_focus == 7) or (_lang_idle and lang is not None) else "○"
        lang_name = f"[ {lang} ]" if lang else "[ Select ]"
        try:
            stdscr.addstr(6, 2, "Lang:  ", curses.color_pair(3))
            stdscr.addstr(6, 9,  f"{lang_dot_auto} Autodetect  ", curses.color_pair(5))
            stdscr.addstr(6, 23, f"{lang_dot_man} ", curses.color_pair(5))
            stdscr.addstr(6, 25, lang_name, curses.color_pair(5))
        except curses.error:
            pass

        # Progress bar (row 8, only while running)
        if progress is not None:
            bar_w = w - 16
            filled = int(bar_w * progress)
            pct = int(progress * 100)
            bar = "█" * filled + "░" * (bar_w - filled)
            try:
                stdscr.addstr(8, 2, f"ffmpeg ", curses.color_pair(3))
                stdscr.addstr(8, 9, f"[", curses.color_pair(3))
                stdscr.addstr(8, 10, bar, curses.color_pair(8))
                stdscr.addstr(8, 10 + bar_w, f"] {pct:3d}%", curses.color_pair(3))
            except curses.error:
                pass

        # Log box
        log_top = 9 if progress is not None else 8
        log_h = h - log_top - 3  # content rows (excludes top and bottom border rows)

        # Buttons: rows 5-7, right-aligned
        # Cancel (10 chars, cols w-12..w-3) always shown; Run (7 chars, cols w-20..w-14) greyed when not ready
        cancel_col = w - 12
        cancel_attr = curses.color_pair(5)
        try:
            stdscr.addstr(5, cancel_col, "┌────────┐", cancel_attr)
            stdscr.addstr(6, cancel_col, "│ Cancel │", cancel_attr)
            stdscr.addstr(7, cancel_col, "└────────┘", cancel_attr)
        except curses.error:
            pass
        run_col = w - 20
        run_attr = curses.color_pair(5) if (selected_file and not running) else curses.color_pair(6)
        try:
            stdscr.addstr(5, run_col, "┌─────┐", run_attr)
            stdscr.addstr(6, run_col, "│ Run │", run_attr)
            stdscr.addstr(7, run_col, "└─────┘", run_attr)
        except curses.error:
            pass
        log_w = w - 4             # total box width including borders
        inner_w = log_w - 2       # text width inside borders
        if log_h > 0:
            scroll_hint = f" ↑{log_scroll} " if log_scroll > 0 else ""
            title = f"Output{scroll_hint}"
            dash_fill = max(0, inner_w - len(title))
            top_line = "┌" + title + "─" * dash_fill + "┐"
            bot_line = "└" + "─" * inner_w + "┘"
            try:
                stdscr.addstr(log_top, 2, top_line[:log_w], curses.color_pair(3) | curses.A_BOLD)
                stdscr.addstr(log_top + log_h + 1, 2, bot_line[:log_w], curses.color_pair(3))
            except curses.error:
                pass
            total = len(log_lines)
            end = total - log_scroll
            start = max(0, end - log_h)
            visible = log_lines[start:end]
            for i in range(log_h):
                row = log_top + 1 + i
                try:
                    stdscr.addstr(row, 2, "│", curses.color_pair(3))
                    stdscr.addstr(row, w - 3, "│", curses.color_pair(3))
                except curses.error:
                    pass
                if i < len(visible):
                    try:
                        stdscr.addstr(row, 3, visible[i][:inner_w], curses.color_pair(7))
                    except curses.error:
                        pass

        # Footer
        if status:
            footer = f" {status} "
        elif running:
            footer = " Running — ↑↓:scroll  Cancel/q:cancel "
        else:
            footer = " Tab:focus  Space:select  ↑↓:scroll  Cancel/q:quit "
        try:
            stdscr.addstr(h - 1, 2, footer[:w - 4], curses.color_pair(6) if inactive else curses.color_pair(5))
        except curses.error:
            pass

        stdscr.refresh()

    def do_run():
        nonlocal running, log_scroll
        if not selected_file or running:
            return
        cancel_event.clear()
        running = True
        log_lines.clear()
        log_scroll = 0
        draw()

        def run_job():
            nonlocal running
            base = os.path.splitext(selected_file)[0]
            wav = base + ".wav"
            try:
                # Get total duration via ffprobe
                total_secs = None
                try:
                    r = subprocess.run(
                        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
                         "-of", "default=noprint_wrappers=1:nokey=1", selected_file],
                        capture_output=True, text=True
                    )
                    total_secs = float(r.stdout.strip())
                except Exception:
                    pass

                log_q.put(("log", "ffmpeg: converting to WAV…"))
                log_q.put(("progress", 0.0))

                proc = subprocess.Popen(
                    ["ffmpeg", "-y", "-i", selected_file, "-vn", "-ac", "1", "-ar", "16000", wav],
                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                    text=True
                )
                current_proc[0] = proc
                for line in proc.stderr:
                    m = TIME_REGEX.search(line)
                    if m and total_secs:
                        elapsed = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))
                        log_q.put(("progress", min(elapsed / total_secs, 1.0)))
                proc.wait()
                current_proc[0] = None

                if proc.returncode != 0:
                    log_q.put(("done",))
                    if not cancel_event.is_set():
                        log_q.put(("log", "ERROR: ffmpeg failed."))
                    return

                log_q.put(("progress", 1.0))
                log_q.put(("log", "ffmpeg: done."))
                log_q.put(("done",))
                log_q.put(("log", f"whisper: loading model '{MODELS_DISPLAY[model_idx]}' (may take a moment)…"))

                env = os.environ.copy()
                env["PYTHONUNBUFFERED"] = "1"

                out_dir = os.path.dirname(os.path.abspath(selected_file))
                whisper_cmd = [f"{VENV}/bin/whisper", wav,
                     "--model", MODELS[model_idx],
                     "--task", "translate",
                     "--output_format", "srt",
                     "--output_dir", out_dir]
                if lang:
                    whisper_cmd += ["--language", LANGUAGE_CODES[lang]]
                proc = subprocess.Popen(
                    whisper_cmd,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    text=True, env=env
                )
                current_proc[0] = proc
                for line in proc.stdout:
                    line = line.rstrip()
                    if line:
                        log_q.put(("log", line))
                proc.wait()
                current_proc[0] = None
                if proc.returncode == 0:
                    log_q.put(("log", "Done! SRT saved alongside source file."))
                elif not cancel_event.is_set():
                    log_q.put(("log", "ERROR: whisper exited with an error."))
            finally:
                current_proc[0] = None
                log_q.put(("done",))
                if os.path.exists(wav):
                    try:
                        os.remove(wav)
                    except OSError:
                        pass
                running = False
                if cancel_event.is_set():
                    log_q.put(("cancelled",))

        t = threading.Thread(target=run_job, daemon=True)
        t.start()

    def do_cancel():
        if running:
            cancel_event.set()
            if current_proc[0]:
                current_proc[0].terminate()
        else:
            quit_requested[0] = True

    draw()

    while True:
        # Drain log queue
        updated = False
        while not log_q.empty():
            msg = log_q.get_nowait()
            kind = msg[0]
            if kind == "log":
                log_lines.append(msg[1])
            elif kind == "progress":
                progress = msg[1]
            elif kind == "done":
                progress = None
            elif kind == "cancelled":
                progress = None
                log_lines.clear()
                log_scroll = 0
                ui_focus = 0
            updated = True
        if updated:
            draw()

        if quit_requested[0]:
            break

        stdscr.timeout(100)
        key = stdscr.getch()

        if key == -1:
            continue
        elif key in (ord("q"), ord("Q"), 27):
            do_cancel()
        elif key in (ord("\t"), curses.KEY_BTAB) and not running:
            ui_focus = (ui_focus + (1 if key == ord("\t") else -1)) % 8
            draw()
        elif key in (ord(" "), curses.KEY_ENTER, 10, 13) and not running and ui_focus == 0:
            start = os.path.dirname(selected_file) if selected_file else os.path.expanduser("~")
            draw(inactive=True)
            picker = FilePicker(stdscr, start)
            result = picker.run()
            if result:
                selected_file = result
            draw()
        elif key == ord(" ") and not running:
            if 1 <= ui_focus <= 5:
                model_idx = ui_focus - 1
                draw()
            elif ui_focus == 6:
                lang = None
                draw()
            elif ui_focus == 7:
                draw(inactive=True)
                lang = pick_language(stdscr, lang)
                draw()
        elif key == curses.KEY_LEFT and not running and 1 <= ui_focus <= 5:
            model_idx = (model_idx - 1) % len(MODELS)
            draw()
        elif key == curses.KEY_RIGHT and not running and 1 <= ui_focus <= 5:
            model_idx = (model_idx + 1) % len(MODELS)
            draw()
        elif key == curses.KEY_DOWN and not running and ui_focus == 7:
            draw(inactive=True)
            lang = pick_language(stdscr, lang)
            draw()
        elif key == curses.KEY_UP and log_lines:
            h, w = stdscr.getmaxyx()
            log_top = 9 if progress is not None else 8
            log_h = h - log_top - 3
            max_scroll = max(0, len(log_lines) - log_h)
            log_scroll = min(log_scroll + 1, max_scroll)
            draw()
        elif key == curses.KEY_DOWN and log_scroll > 0 and (running or ui_focus != 7):
            log_scroll = max(0, log_scroll - 1)
            draw()
        elif key == curses.KEY_MOUSE:
            try:
                _, mx, my, _, bstate = curses.getmouse()
                h, w = stdscr.getmaxyx()
                log_top = 9 if progress is not None else 8
                scroll_up   = bstate & curses.BUTTON4_PRESSED
                scroll_down = bstate & getattr(curses, "BUTTON5_PRESSED", 2097152)
                click       = bstate & (curses.BUTTON1_CLICKED | curses.BUTTON1_PRESSED)
                # Scroll wheel — works even while running
                if scroll_up and log_lines:
                    log_h = h - log_top - 3
                    max_scroll = max(0, len(log_lines) - log_h)
                    log_scroll = min(log_scroll + 1, max_scroll)
                    draw()
                elif scroll_down and log_scroll > 0:
                    log_scroll = max(0, log_scroll - 1)
                    draw()
                elif click and 5 <= my <= 7 and w - 12 <= mx <= w - 3:
                    # Cancel button (rows 5-7, cols w-12..w-3) — works while running too
                    do_cancel()
                elif click and not running:
                    # Run button (rows 5-7, cols w-20..w-14)
                    if selected_file and 5 <= my <= 7 and w - 20 <= mx <= w - 14:
                        do_run()
                    # File button row 2
                    elif my == 2:
                        file_inner = os.path.basename(selected_file) if selected_file else "Select"
                        if 9 <= mx <= min(13 + len(file_inner), w - 3):
                            start = os.path.dirname(selected_file) if selected_file else os.path.expanduser("~")
                            draw(inactive=True)
                            picker = FilePicker(stdscr, start)
                            result = picker.run()
                            if result:
                                selected_file = result
                            draw()
                    # Model row 4
                    elif my == 4:
                        x = 9
                        for i, m in enumerate(MODELS_DISPLAY):
                            label = f"○ {m}  "
                            if x <= mx < x + len(label):
                                model_idx = i
                                ui_focus = i + 1
                                break
                            x += len(label)
                        draw()
                    # Lang row 6
                    elif my == 6:
                        if 9 <= mx <= 20:       # Autodetect: ○ Autodetect (cols 9-20)
                            lang = None
                            ui_focus = 6
                            draw()
                        elif 23 <= mx <= 24 + len(f"[ {lang} ]" if lang else "[ Select ]"):  # Manual: ○ <name>
                            ui_focus = 7
                            draw(inactive=True)
                            lang = pick_language(stdscr, lang)
                            draw()
            except curses.error:
                pass
try:
    curses.wrapper(main)
except KeyboardInterrupt:
    pass
PYTHON_EOF

"${VENV}/bin/python3" "$TMPPY" "${VENV}"
