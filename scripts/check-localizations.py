#!/usr/bin/env python3
"""Check the shared UI catalog against source keys, languages and placeholders."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANGUAGES = {"en", "zh-Hans", "es", "fr", "de", "ja", "pt-BR", "ko", "it", "ru"}
CATALOG = ROOT / "Packages/Spacebar3DKit/Sources/ModelCore/Resources/Localizable.xcstrings"


def main():
    catalog = json.loads(CATALOG.read_text())["strings"]
    used = set()
    for directory in [ROOT / "Spacebar3D", ROOT / "Packages/Spacebar3DKit/Sources"]:
        for source in directory.rglob("*.swift"):
            for key in re.findall(r'L10n\.(?:text|format)\("((?:\\.|[^"\\])*)"', source.read_text()):
                used.add(key.replace(r"\n", "\n").replace(r'\"', '"').replace(r"\\", "\\"))
    errors = [f"Missing catalog key: {key}" for key in used - catalog.keys()]
    for key, entry in catalog.items():
        translations = entry.get("localizations", {})
        if set(translations) != LANGUAGES:
            errors.append(f"Wrong language set: {key}")
        for language, value in translations.items():
            unit = value.get("stringUnit", {})
            text = unit.get("value", "")
            if unit.get("state") != "translated" or not text:
                errors.append(f"Untranslated {language}: {key}")
            if re.findall(r"%(?:\d+\$)?@", text) != re.findall(r"%(?:\d+\$)?@", key):
                errors.append(f"Changed placeholders {language}: {key}")
    if errors:
        raise SystemExit("\n".join(errors))
    print(f"{len(catalog)} entries, {len(LANGUAGES)} languages; all {len(used)} source keys covered.")


if __name__ == "__main__":
    main()
