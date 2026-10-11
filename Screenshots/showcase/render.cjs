// Render original screenshots over the imagegen background without redrawing UI.
// Requires sharp and @napi-rs/canvas on Node's module path.
const fs = require("node:fs/promises");
const path = require("node:path");
const sharp = require("sharp");
const { createCanvas, loadImage, GlobalFonts } = require("@napi-rs/canvas");

const root = __dirname;
const width = 2560;
const height = 1600;
const textLeft = 100;
const frame = { x: 868, y: 230, width: 1592 };
frame.height = Math.round(frame.width * 1790 / 2496);
const headlineSize = 82;
const descriptionSize = 34;

function font(size, weight = 400) {
  return `${weight} ${size}px "Showcase Sans", "Helvetica Neue", Arial, sans-serif`;
}

function trackedText(ctx, value, x, y, spacing) {
  for (const char of value) {
    ctx.fillText(char, x, y);
    x += ctx.measureText(char).width + spacing;
  }
  return x;
}

function assertTextFits(ctx, text, available, label) {
  const actual = ctx.measureText(text).width;
  if (actual > available) {
    throw new Error(`${label} is too wide: ${Math.ceil(actual)} > ${available}`);
  }
}

async function main() {
  const fontCandidates = [
    process.env.SHOWCASE_FONT,
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/HelveticaNeue.ttc"
  ].filter(Boolean);
  for (const candidate of fontCandidates) {
    try {
      await fs.access(candidate);
      if (GlobalFonts.registerFromPath(candidate, "Showcase Sans")) break;
    } catch {
      // Use the next available local font; no font files are redistributed.
    }
  }

  const cards = JSON.parse(await fs.readFile(path.join(root, "captions.json"), "utf8"));
  const background = await loadImage(path.join(root, "background.png"));
  const icon = await loadImage(
    await sharp(path.join(root, "brand-icon.png")).trim().png().toBuffer()
  );
  await fs.mkdir(path.join(root, "web"), { recursive: true });

  for (const card of cards) {
    const canvas = createCanvas(width, height);
    const ctx = canvas.getContext("2d");
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = "high";
    ctx.drawImage(background, 0, 0, width, height);

    ctx.drawImage(icon, textLeft, 270, 104, 104);
    ctx.fillStyle = "#20252B";
    ctx.font = font(46, 600);
    ctx.fillText("DriveClue", 238, 316);
    ctx.fillStyle = "#656D76";
    ctx.font = font(27);
    ctx.fillText("for macOS", 238, 357);

    ctx.fillStyle = "#54697A";
    ctx.font = font(21, 500);
    const labelRight = trackedText(ctx, card.label, textLeft, 550, 4);
    if (labelRight > frame.x - 70) throw new Error("Feature label overlaps screenshot");

    ctx.fillStyle = "#20252B";
    ctx.font = font(headlineSize, 600);
    card.headlineLines.forEach((line, index) => {
      assertTextFits(ctx, line, frame.x - textLeft - 64, card.feature);
      ctx.fillText(line, textLeft, 646 + index * 99);
    });

    ctx.fillStyle = "#59636E";
    ctx.font = font(descriptionSize);
    card.descriptionLines.forEach((line, index) => {
      assertTextFits(ctx, line, frame.x - textLeft - 76, card.feature + " description");
      ctx.fillText(line, textLeft, 854 + index * 53);
    });

    ctx.save();
    ctx.shadowColor = "rgba(22, 30, 40, 0.18)";
    ctx.shadowBlur = 48;
    ctx.shadowOffsetY = 20;
    ctx.fillStyle = "#D8DDE1";
    ctx.beginPath();
    ctx.roundRect(frame.x, frame.y, frame.width, frame.height, 27);
    ctx.fill();
    ctx.restore();

    const cropped = await sharp(path.join(root, card.original))
      .extract(card.crop)
      .png()
      .toBuffer();
    const screenshot = await loadImage(cropped);
    ctx.save();
    ctx.beginPath();
    ctx.roundRect(frame.x, frame.y, frame.width, frame.height, 27);
    ctx.clip();
    ctx.drawImage(screenshot, frame.x, frame.y, frame.width, frame.height);
    ctx.restore();

    ctx.strokeStyle = "rgba(43, 52, 62, 0.16)";
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.roundRect(frame.x + 0.5, frame.y + 0.5, frame.width - 1, frame.height - 1, 27);
    ctx.stroke();

    const png = canvas.toBuffer("image/png");
    await fs.writeFile(path.join(root, card.png), png);
    await sharp(png).webp({ quality: 94, effort: 6 }).toFile(path.join(root, card.webp));
    console.log(JSON.stringify({
      asset: card.png,
      width,
      height,
      pngBytes: png.length,
      webpBytes: (await fs.stat(path.join(root, card.webp))).size,
      screenshot: card.original,
      screenshotRect: frame
    }));
  }
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
