"""Render actual offline compose fixtures; approximate font, never game evidence."""
import argparse
import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]


def render(source, output):
    scene = json.loads(source.read_text(encoding="utf-8"))
    width, height = scene["width"], scene["height"]
    image = Image.new("RGB", (width, height), (9, 13, 17))
    draw = ImageDraw.Draw(image)
    fonts = {}
    for command in sorted(scene["commands"], key=lambda value: value["depth"]):
        color = tuple(command["c"])
        x, y = command["x"], height - command["y"]
        if command["type"] == "rect":
            draw.rectangle((x, y-command["h"], x+command["w"], y), fill=color)
        else:
            size = max(1, round(command["size"]))
            if size not in fonts:
                fonts[size] = ImageFont.truetype("C:/Windows/Fonts/bahnschrift.ttf", size)
            draw.text((x, y), command["text"], fill=color, font=fonts[size], anchor="ls")
    captioned = Image.new("RGB", (width, height+34), (9, 13, 17))
    captioned.paste(image,(0,34));image=captioned;draw=ImageDraw.Draw(image)
    draw.text((24, 8), "OFFLINE COMPOSE PREVIEW / APPROXIMATE FONT", fill=(153, 166, 175), font=ImageFont.truetype("C:/Windows/Fonts/bahnschrift.ttf", 17))
    image.save(output)
    return image


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    sources = sorted((ROOT / "tests/tmp").glob("ui-*.json"))
    if not sources:
        raise SystemExit("Run tests/run.py first to compose the fixtures.")
    tiles = []
    for source in sources:
        image = render(source, args.output / (source.stem + ".png"))
        image.thumbnail((768, 432))
        tile = Image.new("RGB", (768, 460), (9, 13, 17))
        tile.paste(image, (0, 28))
        ImageDraw.Draw(tile).text((12, 7), source.stem.removeprefix("ui-").upper(), fill=(221, 184, 105))
        tiles.append(tile)
    sheet = Image.new("RGB", (768*2, 460*((len(tiles)+1)//2)), (9, 13, 17))
    for index, tile in enumerate(tiles):
        sheet.paste(tile, (index%2*768, index//2*460))
    sheet.save(args.output / "contact-sheet.png")
    print(args.output / "contact-sheet.png")


if __name__ == "__main__":
    main()
