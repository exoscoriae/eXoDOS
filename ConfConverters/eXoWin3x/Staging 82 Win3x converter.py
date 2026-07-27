import configparser
import sys
from pathlib import Path
import msvcrt
import re
import subprocess
import os
import ctypes

kernel32 = ctypes.windll.kernel32
kernel32.SetConsoleMode(kernel32.GetStdHandle(-11), 7)

# Track converted conf files
CONVERTED_CONF_PATHS = []

# Track the folders or files the user dragged
DRAG_ROOTS = []

# ---------------------------------------------------------
#  GLOBAL COLOURS
# ---------------------------------------------------------
RED    = "\033[91m"
GREEN  = "\033[92m"
YELLOW = "\033[93m"
CYAN   = "\033[96m"
RESET  = "\033[0m"

# ---------------------------------------------------------
#  TEMPLATE MUST SIT NEXT TO THIS SCRIPT
# ---------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent
TEMPLATE_82_PATH = SCRIPT_DIR / "Staging 82 eXoWin3x Template.conf"

if not TEMPLATE_82_PATH.exists():
    print(f"ERROR: Missing required template file:\n{TEMPLATE_82_PATH}")
    print("\nPress any key to close...")
    msvcrt.getch()
    sys.exit(1)

# ---------------------------------------------------------
#  SOURCE DETECTION (FIRST LINE)
# ---------------------------------------------------------

def detect_source(conf_path: Path) -> str:
    try:
        with open(conf_path, "r", encoding="utf-8") as f:
            first = f.readline().strip().lower()
    except Exception:
        return "ece"

    if "dosbox-0.74" in first:
        return "vanilla"
    if "dosbox-ece" in first:
        return "ece"
    if "dosbox-staging 0.81" in first:
        return "staging81"
    if "dosbox-staging 0.82" in first:
        return "staging82"
    if "dosbox staging (0.82.2)" in first:
        return "staging82"
    if "dosbox-x" in first:
        return "dosboxx"
    if "dosbox 0.82.18" in first:
        return "dosboxx"
    if "[sdl]" in first:
        return "ece"
    return "ece"

# ---------------------------------------------------------
#  MAPPING TABLES (ECE-STYLE ENGINE, USED FOR ECE/0.74/81)
# ---------------------------------------------------------

KEY_IGNORE = {
    ("sdl", "fullscreen"), ("sdl", "fullresolution"),
    ("sdl", "windowresolution"), ("mouse", "ps2_mouse_model"),
    ("sdl", "output"), ("render", "aspect"),
    ("sdl", "priority"), ("sdl", "mapperfile"),
    ("mixer", "blocksize"), ("mixer", "prebuffer"),
    ("render", "glshader"), ("sdl", "sensitivity"),
    ("midi", "mididevice"),
}

IGNORE_SECTIONS = {"pci", "capture", "mt32", "composite", "voodoo", "imfc", "innovation"}

SILENT_IGNORE_KEYS = {
    ("speaker", "pcrate"), ("speaker", "tandyrate"), ("speaker", "disneyrate"),
    ("sdl", "surfacenp-sharpness"), ("fluidsynth", "soundfont"),
    ("sblaster", "oplrate"), ("sblaster", "oplemu"),
    ("gus", "gusrate"), ("sdl", "fullborderless"),
    ("sdl", "fulldouble"), ("sdl", "usescancodes"), ("render", "scaler"),
    ("midi", "fluid.soundfont"), ("dosbox", "captures"),
    ("mixer", "rate"), ("dos", "keyboardlayout"),
    ("dosbox", "language"), ("sdl", "waitonerror"),
    ("midi", "midiconfig"), ("sdl", "glfullvsync"),
    ("sblaster", "fmstrength"), ("sdl", "autolock"),
    ("speaker", "lpt_dac"),
    ("speaker", "tandy"), ("speaker", "disney"),
    ("speaker", "ps1audio"), ("render", "monochrome_palette"),
    ("dos", "pcjr_memory_config"),
}

# ---------------------------------------------------------
#  STAGING 81 DEFAULT VALUES (FOR SILENT IGNORE)
# ---------------------------------------------------------
STAGING81_DEFAULTS = {
    ("sdl", "display"): "0",
    ("sdl", "window_position"): "auto",
    ("sdl", "window_decorations"): "true",
    ("sdl", "transparency"): "0",
    ("sdl", "host_rate"): "auto",
    ("sdl", "vsync"): "auto",
    ("sdl", "vsync_skip"): "0",
    ("sdl", "presentation_mode"): "auto",
    ("sdl", "mute_when_inactive"): "false",
    ("sdl", "pause_when_inactive"): "false",
    ("sdl", "screensaver"): "auto",

    ("dosbox", "vesa_modes"): "compatible",
    ("dosbox", "vga_8dot_font"): "false",
    ("dosbox", "speed_mods"): "true",
    ("dosbox", "autoexec_section"): "join",
    ("dosbox", "automount"): "true",
    ("dosbox", "startup_verbosity"): "auto",
    ("dosbox", "allow_write_protected_files"): "true",
    ("dosbox", "shell_config_shortcuts"): "true",

    ("render", "cga_colors"): "default",

    ("mouse", "vmware_mouse"): "true",
    ("mouse", "virtualbox_mouse"): "true",

    ("mixer", "negotiate"): "false",
    ("mixer", "compressor"): "true",
    ("mixer", "crossfeed"): "off",
    ("mixer", "reverb"): "off",
    ("mixer", "chorus"): "off",

    ("midi", "raw_midi_output"): "false",

    ("fluidsynth", "fsynth_chorus"): "auto",
    ("fluidsynth", "fsynth_reverb"): "auto",
    ("fluidsynth", "fsynth_filter"): "off",

    ("mt32", "model"): "auto",
    ("mt32", "mt32_filter"): "off",

    ("sblaster", "sbwarmup"): "100",
    ("sblaster", "opl_fadeout"): "off",
    ("sblaster", "sb_filter_always_on"): "false",
    ("sblaster", "opl_filter"): "auto",
    ("sblaster", "cms_filter"): "on",

    ("gus", "gus_filter"): "off",

    ("imfc", "imfc_base"): "2a20",
    ("imfc", "imfc_irq"): "3",
    ("imfc", "imfc_filter"): "on",

    ("innovation", "sidclock"): "default",
    ("innovation", "sidport"): "280",
    ("innovation", "6581filter"): "50",
    ("innovation", "8580filter"): "50",
    ("innovation", "innovation_filter"): "off",

    ("speaker", "pcspeaker_filter"): "on",
    ("speaker", "tandy_fadeout"): "off",
    ("speaker", "tandy_filter"): "on",
    ("speaker", "tandy_dac_filter"): "on",
    ("speaker", "lpt_dac_filter"): "on",
    ("speaker", "ps1audio_filter"): "on",
    ("speaker", "ps1audio_dac_filter"): "on",

    ("dos", "locale_period"): "modern",
    ("dos", "country"): "auto",
    ("dos", "expand_shell_variable"): "auto",
    ("dos", "shell_history_file"): "shell_history.txt",
    ("dos", "setver_table_file"): "",

    ("ethernet", "nicbase"): "300",
    ("ethernet", "nicirq"): "3",
    ("ethernet", "macaddr"): "AC:DE:48:88:99:AA",
    ("ethernet", "tcp_port_forwards"): "",
    ("ethernet", "udp_port_forwards"): "",
}

# ---------------------------------------------------------
#  STAGING 82 DEFAULTS (FOR SILENT IGNORE OF EXTRAS)
# ---------------------------------------------------------

SERIAL_DEFAULTS_82 = {
    "serial2": "dummy",
    "serial3": "disabled",
    "serial4": "disabled",
}

SBLASTER_DEFAULTS_82 = {
    "sbbase": "220",
    "irq": "7",
    "dma": "1",
    "hdma": "5",
}

GUS_DEFAULTS_82 = {
    "gusbase": "240",
    "gusirq": "5",
    "gusdma": "3",
}

JOYSTICK_DEFAULTS_82 = {
    "swap34": "false",
    "buttonwrap": "false",
}

DOSBOX_DEFAULTS_82 = {
    "vmem_delay": "off",
    "dos_rate": "default",
    "vga_render_per_scanline": "true",
}

RENDER_DEFAULTS_82 = {
    "viewport": "fit",
}

DOS_DEFAULTS_82 = {
    "pcjr_memory_config": "expanded",
}

MIDI_DEFAULTS_82 = {
    "mpu401": "intelligent",
}

MIXER_DEFAULTS_82 = {
    "blocksize": "1024",
    "prebuffer": "25",
}

CPU_DEFAULTS = {
    "cycleup": "10",
    "cycledown": "20",
}

# ---------------------------------------------------------
#  SILENT PATTERN IGNORE
# ---------------------------------------------------------

def is_silent_pattern_ignore(section, key):
    s = section.lower()
    k = key.lower()

    if s == "midi" and k.startswith("fluid."):
        return True

    if s == "midi" and k.startswith("mt32."):
        return True

    return False

# ---------------------------------------------------------
#  GENERIC HELPERS
# ---------------------------------------------------------

def find_key_line(lines, section, key_prefix):
    current = None
    key_prefix = key_prefix.lower()
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            current = stripped[1:-1].lower()
        elif current == section and stripped.lower().startswith(key_prefix):
            return i
    return None

def insert_after_key(lines, section, anchor_key, new_lines):
    if not new_lines:
        return
    anchor = find_key_line(lines, section, anchor_key)
    if anchor is None:
        return
    pos = anchor + 1
    for nl in new_lines:
        lines.insert(pos, nl)
        pos += 1

def ensure_blank_after_section(lines, section):
    current = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if current == section:
                if lines[i - 1].strip() != "":
                    lines.insert(i, "\n")
                return
            current = stripped[1:-1].lower()

def update_template_key(output_lines, section_positions, template82,
                        section, key, new_value, changed):
    s = section.lower()
    k = key.lower()
    if s in section_positions and k in section_positions[s]:
        idx = section_positions[s][k]
        old = template82[s][k]
        if old != new_value:
            output_lines[idx] = f"{k} = {new_value}\n"
            changed.append((s, k, old, new_value))
        return True
    return False

def record_unmapped(unmapped, section, key, value):
    unmapped.append((section, key, value))

def insert_collected_keys(output_lines, section, anchor_key,
                          ordered_keys, extras_dict, inserted_added):
    lines = []
    for k in ordered_keys:
        if k in extras_dict:
            lines.append(f"{k} = {extras_dict[k]}\n")
            inserted_added.append((section, k, extras_dict[k]))
    insert_after_key(output_lines, section, anchor_key, lines)

def should_silent_ignore_default(section, key, value, source_label):
    s = section.lower()
    k = key.lower()
    v = value.strip().lower()

    # Staging 81 defaults (only when source_label is 81)
    if source_label == "Dosbox-Staging 0.81.x":
        key_tuple = (s, k)
        if key_tuple in STAGING81_DEFAULTS:
            default_val = STAGING81_DEFAULTS[key_tuple].lower()
            if v == default_val:
                return True
            # if different, we treat as unmapped, not silent ignore
            return False

    # Mixer defaults (blocksize, prebuffer)
    if s == "mixer" and k in MIXER_DEFAULTS_82:
        if v == MIXER_DEFAULTS_82[k].lower():
            return True

        # Vanilla 0.74 or ECE special case for prebuffer
        if k == "prebuffer" and v == "20":
            return True

        return False

    # CPU cycleup/cycledown defaults
    if s == "cpu" and k in CPU_DEFAULTS:
        if v == CPU_DEFAULTS[k]:
            return True
        return False

    # Serial defaults
    if s == "serial" and k in SERIAL_DEFAULTS_82:
        if v == SERIAL_DEFAULTS_82[k]:
            return True
        return False

    # SBLASTER defaults
    if s == "sblaster" and k in SBLASTER_DEFAULTS_82:
        if v == SBLASTER_DEFAULTS_82[k]:
            return True
        return False

    # GUS defaults
    if s == "gus" and k in GUS_DEFAULTS_82:
        if v == GUS_DEFAULTS_82[k]:
            return True
        return False

    # Joystick defaults
    if s == "joystick" and k in JOYSTICK_DEFAULTS_82:
        if v == JOYSTICK_DEFAULTS_82[k]:
            return True
        return False

    # DOSBox extras defaults
    if s == "dosbox" and k in DOSBOX_DEFAULTS_82:
        if v == DOSBOX_DEFAULTS_82[k]:
            return True
        return False

    # Render extras defaults
    if s == "render" and k in RENDER_DEFAULTS_82:
        if v == RENDER_DEFAULTS_82[k]:
            return True
        return False

    # DOS extras defaults
    if s == "dos" and k in DOS_DEFAULTS_82:
        if v == DOS_DEFAULTS_82[k]:
            return True
        return False

    # MIDI extras defaults (mpu401)
    if s == "midi" and k in MIDI_DEFAULTS_82:
        if v == MIDI_DEFAULTS_82[k]:
            return True
        return False

    return False

# ---------------------------------------------------------
#  VALUE TRANSLATION
# ---------------------------------------------------------

def translate_value(section, key, value, template82):
    s = section.lower()
    k = key.lower()
    v = value

    # CPU cputype normalization
    if s == "cpu" and k == "cputype":
        vt = v.strip().lower()
        if vt in ("auto", "386", "386_slow"):
            return "386" if vt != "auto" else "auto"
        if vt == "386_prefetch":
            return "386_prefetch"
        if vt == "486_slow":
            return "486"
        if vt == "pentium_slow":
            return "pentium"
        return v

    # dosbox machine
    if s == "dosbox" and k == "machine":
        return "svga_paradise" if v.strip().lower() == "vgaonly" else v

    # serial directserial → direct
    if s == "serial" and k in ("serial1", "serial2", "serial3", "serial4"):
        tokens = v.strip().split()
        if not tokens:
            return v
        mode = tokens[0].lower()
        args = tokens[1:]
        if mode == "directserial":
            mode = "direct"
        return mode + (" " + " ".join(args) if args else "")

    return v

# ---------------------------------------------------------
#  UNIFIED CONVERSION ENGINE (ECE / 0.74 / 81)
# ---------------------------------------------------------

def convert_config_unified(conf_path: Path, source_label: str):
    with open(TEMPLATE_82_PATH, "r", encoding="utf-8") as f:
        template_lines = f.readlines()

    template82 = configparser.ConfigParser(
        allow_no_value=True, strict=False, interpolation=None
    )
    conf_src = configparser.ConfigParser(
        allow_no_value=True, strict=False, interpolation=None
    )

    template82.read(TEMPLATE_82_PATH, encoding="utf-8")
    conf_src.read(conf_path, encoding="utf-8")

    output_lines = template_lines.copy()

    changed = []
    unmapped = []
    ignored_diff = []
    inserted_added = []
    leftover_sections = set()
    
    user_cycles_override = None

    section_positions = {}
    current_section = None
    for idx, line in enumerate(output_lines):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            current_section = stripped[1:-1].lower()
            section_positions[current_section] = {}
        elif "=" in line and current_section:
            key = line.split("=", 1)[0].strip().lower()
            section_positions[current_section][key] = idx

    serial_extras = {}
    sblaster_extras = {}
    gus_extras = {}
    joystick_extras = {}
    midi_extras = {}
    dosbox_extras = {}
    render_extras = {}
    dos_extras = {}

    for section in conf_src.sections():
        ssection = section.lower()

        if ssection == "autoexec":
            continue

        if ssection in IGNORE_SECTIONS:
            continue

        if section not in template82:
            leftover_sections.add(section)
            for key, value in conf_src[section].items():
                record_unmapped(unmapped, section, key, value)
            continue

        for key, value in conf_src[section].items():
            skey = key.strip().lower()

            # STAGING 81 DEFAULT-IGNORE LOGIC (handled via helper)
            if source_label == "Dosbox-Staging 0.81.x":
                key_tuple = (ssection, skey)
                if key_tuple in STAGING81_DEFAULTS:
                    default_val = STAGING81_DEFAULTS[key_tuple]
                    if value.strip().lower() == default_val.lower():
                        continue  # silent ignore
                    else:
                        record_unmapped(unmapped, section, key, value)
                        continue

            # Silent ignores (explicit + pattern)
            if (ssection, skey) in SILENT_IGNORE_KEYS or is_silent_pattern_ignore(ssection, skey):
                continue

            # mixer blocksize / prebuffer via defaults helper
            if ssection == "mixer" and skey in ("blocksize", "prebuffer"):
                if should_silent_ignore_default(ssection, skey, value, source_label):
                    continue
                record_unmapped(unmapped, section, key, value)
                continue

            # KEY_IGNORE (keep template, log diff)
            if (ssection, skey) in KEY_IGNORE:

                # --- SPECIAL CASE: [sdl] sensitivity ---
                # Template equivalent is [mouse] mouse_sensitivity
                if ssection == "sdl" and skey == "sensitivity":
                    tmpl = template82.get("mouse", "mouse_sensitivity", fallback="")
                    if tmpl != value:
                        ignored_diff.append(("mouse", "mouse_sensitivity", tmpl, value))
                    continue

                # --- NORMAL IGNORE BEHAVIOUR ---
                tmpl = template82[ssection].get(skey, "")
                if tmpl != value:
                    ignored_diff.append((ssection, skey, tmpl, value))
                continue
                
            # --------------------------------------------------------------------
            # SPECIAL CASE: [mouse] mouse_sensitivity (Win3x rules)
            # --------------------------------------------------------------------
            if ssection == "mouse" and skey == "mouse_sensitivity":

                tmpl_val = template82.get("mouse", "mouse_sensitivity", fallback="")

                # 1. Silently ignore if source == template default (40)
                if value == tmpl_val:
                    continue

                # 2. If source == 100 → ignore + log
                if value == "100":
                    ignored_diff.append(("mouse", "mouse_sensitivity", tmpl_val, value))
                    continue

                # 3. Otherwise → map (overwrite template)
                template82["mouse"]["mouse_sensitivity"] = value
                changed.append(("mouse", "mouse_sensitivity", tmpl_val, value))
                continue

            # frameskip: only log as unmapped if non-zero
            if ssection == "render" and skey == "frameskip":
                val = value.strip()
                if val == "0":
                    continue
                record_unmapped(unmapped, section, key, value)
                continue

            # nosound: only log if enabled
            if ssection == "mixer" and skey == "nosound":
                val = value.strip().lower()
                if val in ("false", "0", "no", "off"):
                    continue
                record_unmapped(unmapped, section, key, value)
                continue

            # SERIAL handling
            if ssection == "serial":
                if skey in ("serial2", "serial3", "serial4"):
                    translated = translate_value(ssection, skey, value, template82).strip()

                    if should_silent_ignore_default(ssection, skey, translated, source_label):
                        continue

                    if translated:
                        serial_extras[skey] = translated
                    continue

                if skey == "serial1":
                    translated = translate_value(ssection, skey, value, template82)
                    if not update_template_key(output_lines, section_positions, template82,
                                               "serial", "serial1", translated, changed):
                        record_unmapped(unmapped, section, key, value)
                    continue

            # SBLASTER handling
            if ssection == "sblaster":
                if skey == "sbmixer":
                    translated = value.strip().lower()
                    idx = find_key_line(output_lines, "sblaster", "sbmixer")
                    if idx is not None:
                        old = output_lines[idx].split("=", 1)[1].strip()
                        if old != translated:
                            output_lines[idx] = f"sbmixer = {translated}\n"
                            changed.append(("sblaster", "sbmixer", old, translated))
                    else:
                        sec_start = find_key_line(output_lines, "sblaster", "")
                        if sec_start is not None:
                            output_lines.insert(sec_start + 1, f"sbmixer = {translated}\n")
                            changed.append(("sblaster", "sbmixer", "(missing)", translated))
                    continue

                if skey in ("sbbase", "irq", "dma", "hdma"):
                    translated = value.strip()

                    if should_silent_ignore_default(ssection, skey, translated, source_label):
                        continue

                    if translated:
                        sblaster_extras[skey] = translated
                    continue

                if skey == "oplmode":
                    if value.strip().lower() == "cms":
                        idx = section_positions["sblaster"]["cms"]
                        old = template82["sblaster"]["cms"]
                        if old != "on":
                            output_lines[idx] = "cms = on\n"
                            changed.append(("sblaster", "cms", old, "on"))
                    else:
                        translated = value.strip().lower()
                        update_template_key(output_lines, section_positions, template82,
                                            "sblaster", "oplmode", translated, changed)
                    continue

            # GUS extras
            if ssection == "gus" and skey in ("gusbase", "gusirq", "gusdma"):
                translated = value.strip()

                if should_silent_ignore_default(ssection, skey, translated, source_label):
                    continue

                if translated:
                    gus_extras[skey] = translated
                continue
                
            # JOYSTICK extras
            if ssection == "joystick" and skey in ("swap34", "buttonwrap"):
                translated = value.strip()

                if should_silent_ignore_default(ssection, skey, translated, source_label):
                    continue

                if translated:
                    joystick_extras[skey] = translated
                continue

            # mpu401 insertion (now unified with extras/defaults)
            if ssection == "midi" and skey == "mpu401":
                val = value.strip().lower()

                if should_silent_ignore_default(ssection, skey, val, source_label):
                    continue

                midi_extras["mpu401"] = val
                continue

            # pcspeaker handling (ECE + 81 discrete/impulse)
            if ssection == "speaker" and skey == "pcspeaker":
                val = value.strip().lower()
                if val in ("true", "on", "1", "yes", "discrete", "impulse"):
                    continue
                if val in ("false", "off", "0", "no", "none"):
                    update_template_key(output_lines, section_positions, template82,
                                        "speaker", "pcspeaker", "off", changed)
                continue

            # cycles → cpu_cycles
            if ssection == "cpu" and skey == "cycles":
                translated = value.strip()
                update_template_key(output_lines, section_positions, template82,
                                    "cpu", "cpu_cycles", translated, changed)
                continue

            # cycleup/cycledown via defaults helper
            if ssection == "cpu" and skey in ("cycleup", "cycledown"):
                if should_silent_ignore_default(ssection, skey, value, source_label):
                    continue
                record_unmapped(unmapped, section, key, value)
                continue

            # dosbox vmem_delay and dos_rate (extras)
            if ssection == "dosbox" and skey in ("vmem_delay", "dos_rate", "vga_render_per_scanline"):
                translated = value.strip().lower()

                if should_silent_ignore_default(ssection, skey, translated, source_label):
                    continue

                dosbox_extras[skey] = translated
                continue

            # render viewport (extras)
            if ssection == "render" and skey == "viewport":
                translated = value.strip().lower()

                if should_silent_ignore_default(ssection, skey, translated, source_label):
                    continue

                render_extras["viewport"] = translated
                continue     

            # memsize: ECE/vanilla clamp, 81 direct map
            if ssection == "dosbox" and skey == "memsize":
                try:
                    n = int(value.strip())
                except ValueError:
                    translated = value.strip()
                else:
                    tmpl = template82["dosbox"]["memsize"]
                    if source_label in ("Dosbox-ECE", "Dosbox 0.74"):
                        if n > 32:
                            ignored_diff.append(("dosbox", "memsize", tmpl, f"{n} (clamped to 32)"))
                            continue
                        if n == 32:
                            continue
                        translated = str(n)
                    else:
                        translated = str(n)

                update_template_key(output_lines, section_positions, template82,
                                    "dosbox", "memsize", translated, changed)
                continue

            # generic translation
            translated = translate_value(ssection, skey, value, template82)
            if ssection in section_positions and skey in section_positions[ssection]:
                update_template_key(output_lines, section_positions, template82,
                                    ssection, skey, translated, changed)
            else:
                record_unmapped(unmapped, section, key, value)

    # ---------------------------------------------------------
    #  INSERT COLLECTED KEYS (GENERIC HELPER)
    # ---------------------------------------------------------

    insert_collected_keys(
        output_lines, "serial", "serial1",
        ["serial2", "serial3", "serial4"],
        serial_extras, inserted_added
    )

    insert_collected_keys(
        output_lines, "sblaster", "sbtype",
        ["sbbase", "irq", "dma", "hdma"],
        sblaster_extras, inserted_added
    )

    insert_collected_keys(
        output_lines, "gus", "gus",
        ["gusbase", "gusirq", "gusdma"],
        gus_extras, inserted_added
    )

    insert_collected_keys(
        output_lines, "joystick", "joysticktype",
        ["swap34", "buttonwrap"],
        joystick_extras, inserted_added
    )

    insert_collected_keys(
        output_lines, "dosbox", "vmemsize",
        ["vmem_delay", "dos_rate", "vga_render_per_scanline"],
        dosbox_extras, inserted_added
    )

    insert_collected_keys(
        output_lines, "render", "integer_scaling",
        ["viewport"],
        render_extras, inserted_added
    )
    
    insert_collected_keys(
        output_lines, "dos", "ver",
        ["pcjr_memory_config"],
        dos_extras, inserted_added
    )

    insert_collected_keys(
        output_lines, "midi", "mididevice",
        ["mpu401"],
        midi_extras, inserted_added
    )

    # ---------------------------------------------------------
    #  ENSURE BLANK LINES AFTER SECTIONS
    # ---------------------------------------------------------
    ensure_blank_after_section(output_lines, "serial")
    ensure_blank_after_section(output_lines, "sblaster")
    ensure_blank_after_section(output_lines, "gus")

    # ---------------------------------------------------------
    #  AUTOEXEC REPLACEMENT (WIN3X VERSION)
    # ---------------------------------------------------------
    
    # The Win3x template PATH line we must always keep
    WIN3X_TEMPLATE_PATH_LINE = "path=C:\\;z:\\;c:\\windows\\;y:\\dos;y:\\"
    
    # Extract template path entries
    template_paths = WIN3X_TEMPLATE_PATH_LINE.split("=", 1)[1].split(";")
    template_paths = [p for p in template_paths if p]

    # ---------------------------------------------------------
    #  EXTRACT SOURCE AUTOEXEC LINES
    # ---------------------------------------------------------
    autoexec_lines = []
    in_autoexec = False
    
    with open(conf_path, "r", encoding="utf-8") as f:
        for line in f:
            stripped = line.strip().lower()
            if stripped == "[autoexec]":
                in_autoexec = True
                autoexec_lines.append("[autoexec]\n")
                continue
            if in_autoexec:
                # Stop when next section begins
                if stripped.startswith("[") and stripped.endswith("]"):
                    break
                autoexec_lines.append(line)
    
    # ---------------------------------------------------------
    #  EXTRACT PATH LINES FROM SOURCE AUTOEXEC
    # ---------------------------------------------------------
    source_paths = []
    
    for line in autoexec_lines:
        stripped = line.strip().lower()
        if stripped.startswith("path="):
            parts = stripped.split("=", 1)[1].split(";")
            for p in parts:
                p = p.strip()
                if p and p not in source_paths:
                    source_paths.append(p)
    
    # ---------------------------------------------------------
    #  MERGE TEMPLATE + SOURCE PATHS
    # ---------------------------------------------------------
    merged_paths = template_paths.copy()
    for p in source_paths:
        if p not in merged_paths:
            merged_paths.append(p)
    
    final_path_line = "path=" + ";".join(merged_paths) + "\n"
    
    # ---------------------------------------------------------
    #  BUILD CLEAN AUTOEXEC SECTION
    # ---------------------------------------------------------
    clean_autoexec = ["[autoexec]\n", final_path_line, "@echo off\n"]
    
    for line in autoexec_lines[1:]:
        stripped = line.strip()
    
        # Skip any PATH lines (we already rebuilt it)
        if stripped.lower().startswith("path="):
            continue
    
        # Skip ANY form of "echo off" (with or without @, any spacing)
        normalized = stripped.lower().replace(" ", "")
        if normalized in ("echooff", "@echooff"):
            continue
    
        # Strip leading '@' from other commands
        if stripped.startswith("@"):
            stripped = stripped[1:]
    
        # Preserve blank lines and comments
        if not stripped:
            clean_autoexec.append("\n")
        else:
            clean_autoexec.append(stripped + "\n")
    
    # ---------------------------------------------------------
    #  REPLACE AUTOEXEC SECTION IN OUTPUT
    # ---------------------------------------------------------
    new_output = []
    in_autoexec = False
    
    for line in output_lines:
        stripped = line.strip().lower()
        if stripped == "[autoexec]":
            in_autoexec = True
            new_output.extend(clean_autoexec)
            continue
        if in_autoexec:
            if stripped.startswith("[") and stripped.endswith("]"):
                in_autoexec = False
                new_output.append(line)
            continue
        new_output.append(line)

    output_lines = new_output
    
    # ---------------------------------------------------------
    #  NEW FEATURE: ASK ABOUT cpu_cycles IF auto/max
    # ---------------------------------------------------------

    # Find final cpu_cycles value in output_lines
    final_cycles = None
    current_section = None

    for line in output_lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            current_section = stripped[1:-1].lower()
            continue
        if current_section == "cpu" and stripped.lower().startswith("cpu_cycles"):
            parts = stripped.split("=", 1)
            if len(parts) == 2:
                final_cycles = parts[1].strip().lower()
            break

    # Only ask if cycles are auto or max
    if final_cycles in ("auto", "max"):

        suggested = "30000"

        print(f"\n{YELLOW}Cycles in the source were set to {final_cycles}.{RESET}")
        print("It is recommended to set a specific cycles value.")
        print("Standard value for Windows 3.x is between 30000 and 60000,")
        print("but the correct value can vary significantly.")

        print(f"\nSuggested cycles value: {CYAN}{suggested}{RESET}")

        # --- INPUT LOOP (full editable suggestion using msvcrt) ---
        while True:
            if suggested:
                print("\nEnter a new cpu_cycles value:")
                buffer = list(suggested)
                print("> " + CYAN + "".join(buffer) + RESET, end="", flush=True)

                while True:
                    ch = msvcrt.getch()
                    if ch in (b"\r", b"\n"):
                        print()
                        break
                    if ch == b"\x08":
                        if buffer:
                            buffer.pop()
                            print("\r> " + " " * (len(suggested) + 10), end="", flush=True)
                            print("\r> " + CYAN + "".join(buffer) + RESET, end="", flush=True)
                        continue
                    if ch < b"0" or ch > b"9":
                        continue
                    buffer.append(ch.decode("utf-8"))
                    print("\r> " + CYAN + "".join(buffer) + RESET, end="", flush=True)

                new_cycles = "".join(buffer).strip()
                if new_cycles == "":
                    new_cycles = suggested
            else:
                print(f"\nEnter a new cpu_cycles value (or press Enter to keep {final_cycles}):")
                line = input("> ").strip()
                if line == "":
                    new_cycles = None
                else:
                    new_cycles = line

            if new_cycles is None:
                break

            if not new_cycles.isdigit():
                print(f"{RED}Please enter a numeric value (e.g., 3000, 12000, 60000).{RESET}")
                continue

            if int(new_cycles) > 200000:
                print(f"{RED}Warning: Values above 200000 may cause instability or timing issues.{RESET}")
                print("Are you sure you want to use this value? (Y/N)")

                while True:
                    ch = msvcrt.getch().decode("utf-8").lower()
                    if ch in ("y", "n"):
                        break

                if ch == "n":
                    continue

                break

            break

        if new_cycles:
            user_cycles_override = new_cycles
            current_section = None
            for i, line in enumerate(output_lines):
                stripped = line.strip()
                if stripped.startswith("[") and stripped.endswith("]"):
                    current_section = stripped[1:-1].lower()
                    continue
                if current_section == "cpu" and stripped.lower().startswith("cpu_cycles"):
                    output_lines[i] = f"cpu_cycles = {new_cycles}\n"
                    print(f"\n{GREEN}cpu_cycles updated to {new_cycles}{RESET}")
                    break


    # ---------------------------------------------------------
    #  WRITE OUTPUT (ECE-STYLE BACKUP)
    # ---------------------------------------------------------
    output_path = conf_path.with_name(conf_path.stem + "_converted_82.conf")

    with open(output_path, "w", encoding="utf-8") as f:
        f.writelines(output_lines)

    backup_path = conf_path.with_name(f"{conf_path.stem} - Copy.conf")
    conf_path.replace(backup_path)
    output_path.replace(conf_path)

    # ---------------------------------------------------------
    #  DIFF REPORT
    # ---------------------------------------------------------
    GENERIC_LABEL = "source"
    
    print(f"\n{CYAN}===== 82.x TEMPLATE VALUES UPDATED FROM SOURCE ====={RESET}\n")
    if not changed:
        print("No template keys were changed.")
    else:
        for sec, key, old, new in changed:
            if sec == "cpu" and key == "cpu_cycles" and user_cycles_override:
                print(f"[cpu] cpu_cycles: {RED}{old}{RESET}  →  {GREEN}{new}{RESET}  "
                      f"(Overridden to: {YELLOW}{user_cycles_override}{RESET})")
            else:
                print(f"[{sec}] {key}: {RED}{old}{RESET}  →  {GREEN}{new}{RESET}")

    print(f"\n{CYAN}===== ADDED KEYS FROM SOURCE ====={RESET}\n")
    if not inserted_added:
        print(f"No keys were added from {GENERIC_LABEL}.")
    else:
        for sec, key, val in inserted_added:
            print(f"[{sec}] {key} = {YELLOW}{val}{RESET}")

    print(f"\n{CYAN}===== UNMAPPED / LEFTOVER VALUES ====={RESET}\n")
    if not unmapped:
        print("No leftover keys.")
    else:
        for sec, key, val in unmapped:
            print(f"{YELLOW}[{sec}] {key} = {val}{RESET}")

    print(f"\n{CYAN}===== DIFFERENT BUT IGNORED ====={RESET}\n")
    if not ignored_diff:
        print("No ignored differences.")
    else:
        for sec, key, tmpl, val in ignored_diff:
            print(f"[{sec}] {key}: {GENERIC_LABEL}={YELLOW}{val}{RESET}  (template kept: {GREEN}{tmpl}{RESET})")

    print(f"\n{CYAN}===== LEFTOVER SECTIONS ====={RESET}\n")
    if not leftover_sections:
        print("No leftover sections.")
    else:
        for sec in sorted(leftover_sections):
            print(f"{YELLOW}{sec}{RESET}")

    print(f"\n[{count}/{total}] Converted file written to:\n{conf_path}")
    
    # ---------------------------------------------------------
    #  FILE_LOCKING ADVISORY (WIN3X ONLY)
    # ---------------------------------------------------------

    # Find final value of [dos] file_locking in output_lines
    final_file_locking = None
    current_section = None

    for line in output_lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            current_section = stripped[1:-1].lower()
            continue

        if current_section == "dos" and stripped.lower().startswith("file_locking"):
            # Extract value after '='
            parts = stripped.split("=", 1)
            if len(parts) == 2:
                final_file_locking = parts[1].strip()
            break

    print(f"\n{CYAN}===== FILE_LOCKING STATUS ====={RESET}\n")

    if final_file_locking is None:
        print("Could not determine final file_locking value.")
    else:
        print(f"[dos] file_locking = {GREEN}{final_file_locking}{RESET}")

    print(
    f"\n{YELLOW}NOTE:{RESET} File locking emulates share.exe. Director 5 and Director 6 games\n"
    f"      require {RED}file_locking=false{RESET} to avoid 'Invalid projector file' error.\n"
    )

    return unmapped, leftover_sections

# ---------------------------------------------------------
#  DRAG‑AND‑DROP ENTRY POINT (MULTI-FILE + MULTI-FOLDER)
# ---------------------------------------------------------
if __name__ == "__main__":
    print("RUNNING:", __file__)
    try:
        if len(sys.argv) < 2:
            print("Drag one or more .conf files or folders onto this script.")
            print("\nPress any key to close...")
            msvcrt.getch()
            sys.exit(1)

        # ---------------------------------------------------------
        #  COLLECT ALL .conf FILES FROM ARGUMENTS
        # ---------------------------------------------------------
        conf_files = []

        for arg in sys.argv[1:]:
            p = Path(arg)

            if p.is_file() and p.suffix.lower() == ".conf":
                conf_files.append(p)
                DRAG_ROOTS.append(p.parent)

            elif p.is_dir():
                found = False
                for f in p.iterdir():
                    if f.is_file() and f.suffix.lower() == ".conf":
                        conf_files.append(f)
                        found = True
                if found:
                    DRAG_ROOTS.append(p)

        if not conf_files:
            print("\nNo .conf files found to process.")
            print("Drag .conf files or folders containing .conf files.")
            print("\nPress any key to close...")
            msvcrt.getch()
            sys.exit(1)

        # Progress counter
        total = len(conf_files)
        count = 0

        # ---------------------------------------------------------
        #  PROCESS EACH CONF FILE IN TURN
        # ---------------------------------------------------------
        for conf_path in conf_files:
            count += 1
            print(f"\n{CYAN}===== [{count}/{total}] Processing: {conf_path} ====={RESET}\n")

            source = detect_source(conf_path)
            converted = False
            unmapped = []
            leftover_sections = set()

            if source == "ece":
                unmapped, leftover_sections = convert_config_unified(conf_path, "Dosbox-ECE")
                converted = True
                CONVERTED_CONF_PATHS.append(conf_path)

            elif source == "vanilla":
                unmapped, leftover_sections = convert_config_unified(conf_path, "Dosbox 0.74")
                converted = True
                CONVERTED_CONF_PATHS.append(conf_path)

            elif source == "staging81":
                unmapped, leftover_sections = convert_config_unified(conf_path, "Dosbox-Staging 0.81.x")
                converted = True
                CONVERTED_CONF_PATHS.append(conf_path)

            elif source == "staging82":
                print(f"\n{YELLOW}Already a Staging 82.x config. Skipping.{RESET}")

            elif source == "dosboxx":
                print(f"\n{RED}DOSBox-X config detected. Skipping (unsupported).{RESET}")

            else:
                print(f"\n{RED}Config missing known fork identifier in first line. Skipping.{RESET}")

            # If not converted, skip to next file
            if not converted:
                continue

            # ---------------------------------------------------------
            #  OPTIONAL: OPEN CONVERTED CONF IF UNMAPPED KEYS
            # ---------------------------------------------------------
            if unmapped or leftover_sections:
                print(f"\n{YELLOW}Unmapped keys or leftover sections detected.{RESET}")
                print(f"{RED}Open converted conf for manual editing? (Y/N){RESET}")

                while True:
                    ch = msvcrt.getch().decode("utf-8").lower()
                    if ch in ("y", "n"):
                        break

                if ch == "y":
                    try:
                        subprocess.Popen(f'cmd /c "start \"\" \"{conf_path}\""', shell=True)
                    except Exception:
                        print(f"\n{RED}Failed to open file. Please open manually:{RESET}")
                        print(conf_path)

            # ---------------------------------------------------------
            #  OPTIONAL: UPDATE dosbox3x.txt
            # ---------------------------------------------------------
            year_pattern = re.compile(r".*\(\d{4}\)\.bat$", re.IGNORECASE)
            conf_dir = conf_path.parent
            candidates = [f for f in conf_dir.iterdir() if f.is_file() and year_pattern.match(f.name)]

            game_key = None
            if len(candidates) == 1:
                game_key = candidates[0].stem
            elif len(candidates) > 1:
                game_key = sorted(candidates)[0].stem

            if game_key:
                dosbox_path = conf_dir.parent.parent.parent / "util" / "dosbox3x.txt"

                if dosbox_path.exists():
                    with open(dosbox_path, "r", encoding="utf-8") as f:
                        lines = f.readlines()

                    entry_index = None
                    for i, line in enumerate(lines):
                        if line.lower().startswith(game_key.lower() + ":"):
                            entry_index = i
                            break

                    if entry_index is not None:
                        current_entry = lines[entry_index].strip()
                        print(f"\nCurrent dosbox3x.txt entry for this game:\n{GREEN}{current_entry}{RESET}")

                        desired = f"{game_key}:staging0.82.2\\dosbox.exe"

                        # Already set → no question
                        if current_entry.lower() == desired.lower():
                            print(f"\n{GREEN}Dosbox3x.txt for this game is already set to Staging 82.2.{RESET}")
                        else:
                            print(f"\n{RED}Would you like to update dosbox3x.txt to use Staging 82.2 for this game? (Y/N){RESET}")
                            while True:
                                ch = msvcrt.getch().decode("utf-8").lower()
                                if ch in ("y", "n"):
                                    break

                            if ch == "y":
                                new_entry = desired + "\n"
                                lines[entry_index] = new_entry

                                with open(dosbox_path, "w", encoding="utf-8") as f:
                                    f.writelines(lines)

                                print(f"\nUpdated entry:\n{new_entry.strip()}")
                                
                    else:
                        # NEW BEHAVIOUR: game not found
                        print(f"\n{YELLOW}No entry for this game was found in dosbox3x.txt.{RESET}")
                        print(f"{RED}Open dosbox3x.txt for manual inspection? (Y/N){RESET}")

                        while True:
                            ch = msvcrt.getch().decode("utf-8").lower()
                            if ch in ("y", "n"):
                                break

                        if ch == "y":
                            try:
                                subprocess.Popen(f'cmd /c "start \"\" \"{dosbox_path}\""', shell=True)
                            except Exception:
                                print(f"\n{RED}Failed to open file. Please open manually:{RESET}")
                                print(dosbox_path)

            # ---------------------------------------------------------
            #  OPTIONAL: RUN GAME
            # ---------------------------------------------------------
            print(f"\n{RED}Do you want to test the game? (Y/N){RESET}")
            while True:
                ch = msvcrt.getch().decode("utf-8").lower()
                if ch in ("y", "n"):
                    break

            if ch == "y":
                conf_dir = conf_path.parent
                candidates = [f for f in conf_dir.iterdir()
                              if f.is_file() and year_pattern.match(f.name)]

                if len(candidates) == 1:
                    bat_to_run = candidates[0]
                    print(f"\nLaunching: {bat_to_run.name}\n")
                    proc = subprocess.Popen(
                        f'start "" /wait cmd /c "{bat_to_run.name}"',
                        cwd=str(conf_dir),
                        shell=True
                    )
                    proc.wait()

                elif len(candidates) == 0:
                    print("\nNo game launcher (.bat with a year) found in this folder.")
                else:
                    print("\nMultiple launchers found:")
                    for f in candidates:
                        print("  -", f.name)
                    print("Not launching automatically.")

        print("\nAll files processed.")
        
        # ---------------------------------------------------------
        #  OPTIONAL: ZIP ALL UPDATED CONF FILES
        # ---------------------------------------------------------
        if CONVERTED_CONF_PATHS:
            print(f"\n{CYAN}Create a zip of all updated conf files? (Y/N){RESET}")

            while True:
                ch = msvcrt.getch().decode("utf-8").lower()
                if ch in ("y", "n"):
                    break

            if ch == "y":
                zip_path = SCRIPT_DIR / "UpdatedConfs.zip"

                # If the default zip already exists, ask for a new name
                if zip_path.exists():
                    print(f"\n{YELLOW}A zip file named UpdatedConfs.zip already exists.{RESET}")
                    print("Enter a new zip filename (without extension):")

                    while True:
                        newname = input("> ").strip()
                        if newname == "":
                            print(f"{RED}Filename cannot be empty.{RESET}")
                            continue

                        # sanitize: remove illegal characters
                        newname = re.sub(r'[<>:\"/\\|?*]', "_", newname)

                        new_zip_path = SCRIPT_DIR / f"{newname}.zip"

                        if new_zip_path.exists():
                            print(f"{RED}{newname}.zip already exists. Please enter a different name.{RESET}")
                            continue

                        zip_path = new_zip_path
                        break

                import zipfile
                with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
                    for p in CONVERTED_CONF_PATHS:

                        # Find the drag root that matches this file
                        root = None
                        for r in DRAG_ROOTS:
                            try:
                                rel = p.relative_to(r)
                                root = r
                                break
                            except ValueError:
                                continue

                        # If no root matched (rare), fall back to filename only
                        if root is None:
                            rel = Path(p.name)
                        else:
                            # If rel is just the filename, prepend the folder name
                            if rel == Path(p.name):
                                rel = Path(root.name) / rel

                        z.write(p, rel)

                print(f"\n{GREEN}Zip created:{RESET}")
                print(f"{CYAN}{zip_path}{RESET}")

        # ---------------------------------------------------------
        #  RESTORE CONSOLE WINDOW BEFORE FINAL PAUSE
        # ---------------------------------------------------------
        try:
            # Uses Windows API via PowerShell to restore the window
            subprocess.Popen(
                'powershell -command "(Get-Process -Id $PID).MainWindowHandle | '
                'ForEach-Object { $hwnd = $_; '
                'if ($hwnd -ne 0) { '
                'Add-Type \\"using System; using System.Runtime.InteropServices; public class W { [DllImport(\\"user32.dll\\")] public static extern bool ShowWindow(IntPtr h, int n); }\\"; '
                '[W]::ShowWindow([IntPtr]$hwnd, 9) } }"',
                shell=True
            )
        except Exception:
            pass  # If restore fails, we still continue safely

        print("\nPress any key to close...")
        msvcrt.getch()

    except Exception as e:
        print("\nERROR OCCURRED:\n", e)
        print("\nPress any key to close...")
        msvcrt.getch()
