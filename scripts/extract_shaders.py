"""Extract all GLSL shaders from mpvnet-20231122.zip into Resources/Shaders/."""

from pathlib import Path
import zipfile

ZIP_PATH = Path.home() / "Downloads" / "mpvnet-20231122.zip"
OUT_DIR = Path(__file__).resolve().parent.parent / "Resources" / "Shaders"
SHADER_PREFIX = "mpvnet/portable_config/shaders/"


def extract_shaders(zip_path: Path = ZIP_PATH, out_dir: Path = OUT_DIR) -> list[Path]:
    if not zip_path.exists():
        raise FileNotFoundError(f"Source archive not found: {zip_path}")

    out_dir.mkdir(parents=True, exist_ok=True)
    extracted: list[Path] = []
    with zipfile.ZipFile(zip_path, "r") as zf:
        for member in zf.namelist():
            if member.startswith(SHADER_PREFIX) and member.lower().endswith(".glsl"):
                filename = Path(member).name
                target = out_dir / filename
                target.write_bytes(zf.read(member))
                extracted.append(target)
    return sorted(extracted)


if __name__ == "__main__":
    files = extract_shaders()
    print(f"Extracted {len(files)} GLSL shaders to {OUT_DIR}")
