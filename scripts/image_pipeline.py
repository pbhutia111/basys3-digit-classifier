"""Prepare one saved handwritten digit for the Basys 3's 16 x 16 input.

This module only processes pixels; it does not recognize digits. Prefer a PNG
export of one digit on plain paper with a small empty border. A well-lit,
straight-on photograph can also work. Crop away other writing, app controls,
and page edges. Grid lines, shadows, perspective, and multiple digits are not
automatically removed and can become part of the FPGA's input.

The output uses MNIST polarity (bright ink on black) regardless of the source.
The final rounding/clipping is the upstream SNN-FPGA UART quantization:
``clip(round(intensity * 256), 0, 255)``. Preprocessing a photograph does not
guarantee that it resembles the model's training data.
"""

from io import BytesIO
from numbers import Integral
from pathlib import Path
import warnings

import numpy as np
from PIL import Image, ImageOps, UnidentifiedImageError


SUPPORTED_FORMATS = frozenset({"PNG", "JPEG", "BMP", "TIFF", "WEBP"})
MAX_DIMENSION = 16_384
MAX_PIXELS = 40_000_000
TARGET_SIZE = 16
INK_SIZE = 12
MIN_CONTRAST = 16.0


def _check_dimensions(image):
    width, height = image.size
    if width < 2 or height < 2:
        raise ValueError("The image must be at least 2 pixels wide and high.")
    if max(width, height) > MAX_DIMENSION or width * height > MAX_PIXELS:
        raise ValueError(
            "The image is too large. Resize it to at most 40 megapixels "
            "and 16384 pixels per side before loading it."
        )


def _upright_rgb(image):
    """Return an independent, upright RGB image with a white alpha backdrop."""
    _check_dimensions(image)
    upright = ImageOps.exif_transpose(image)
    if "A" in upright.getbands() or "transparency" in upright.info:
        rgba = upright.convert("RGBA")
        backdrop = Image.new("RGBA", rgba.size, "white")
        return Image.alpha_composite(backdrop, rgba).convert("RGB")
    return upright.convert("RGB")


def load_image(path):
    """Load a static PNG/JPEG/BMP/TIFF/WebP and return a detached RGB image.

    Validate the decoded format rather than relying on its filename extension.
    Apply EXIF orientation and composite transparency onto white before return.
    Animated or multipage images are rejected instead of silently choosing a
    frame. Unsupported, invalid, and oversized images raise ``ValueError``;
    filesystem errors such as a missing file retain their ``OSError`` type.
    """
    return _load_image_source(Path(path))


def load_image_bytes(data: bytes) -> Image.Image:
    """Decode a captured file's bytes using the same rules as :func:`load_image`.

    Callers can hash these same bytes to identify exactly what was decoded,
    even if the source file changes later. The returned RGB image is detached
    from the input buffer. Encoded-file size limits belong to the caller;
    decoded dimensions and pixel count are checked here.
    """
    if not isinstance(data, bytes):
        raise TypeError("data must contain the image file's bytes.")
    with BytesIO(data) as source:
        return _load_image_source(source)


def _load_image_source(source):
    """Common validation and eager decoding for paths and byte streams."""
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(source) as image:
                if image.format not in SUPPORTED_FORMATS:
                    raise ValueError(
                        "Unsupported image format. Export a PNG or JPEG, "
                        "or use a static BMP, TIFF, or WebP."
                    )
                _check_dimensions(image)
                if getattr(image, "n_frames", 1) != 1:
                    raise ValueError(
                        "Use a single image, not an animation or multipage file."
                    )
                image.load()
                return _upright_rgb(image)
    except (Image.DecompressionBombWarning, Image.DecompressionBombError) as error:
        raise ValueError("The image is too large. Resize it before loading it.") from error
    except UnidentifiedImageError as error:
        raise ValueError("This file is not a readable supported raster image.") from error


def _crop(image, crop_box):
    if crop_box is None:
        return image
    try:
        coordinates = tuple(crop_box)
    except TypeError as error:
        raise ValueError("Crop must contain four integer pixel coordinates.") from error
    if len(coordinates) != 4 or any(
        isinstance(value, bool) or not isinstance(value, Integral)
        for value in coordinates
    ):
        raise ValueError("Crop must contain four integer pixel coordinates.")
    left, top, right, bottom = map(int, coordinates)
    if not (0 <= left < right <= image.width and 0 <= top < bottom <= image.height):
        raise ValueError("Crop must have positive area and lie within the image.")
    if right - left < 2 or bottom - top < 2:
        raise ValueError("Crop must be at least 2 pixels wide and high.")
    return image.crop((left, top, right, bottom))


def _center_by_mass(canvas):
    """Subpixel translation with bilinear interpolation and zero padding."""
    yy, xx = np.indices(canvas.shape, dtype=np.float32)
    mass = float(canvas.sum())
    if mass <= 0:
        raise ValueError("No visible digit remains after resizing. Try a clearer crop.")
    center = (TARGET_SIZE - 1) / 2.0
    delta_y = center - float((canvas * yy).sum()) / mass
    delta_x = center - float((canvas * xx).sum()) / mass
    source_y, source_x = yy - delta_y, xx - delta_x
    y0, x0 = np.floor(source_y).astype(int), np.floor(source_x).astype(int)
    fy, fx = source_y - y0, source_x - x0
    centered = np.zeros_like(canvas)
    for dy, wy in ((0, 1 - fy), (1, fy)):
        for dx, wx in ((0, 1 - fx), (1, fx)):
            sy, sx = y0 + dy, x0 + dx
            valid = (sy >= 0) & (sy < TARGET_SIZE) & (sx >= 0) & (sx < TARGET_SIZE)
            centered[valid] += canvas[sy[valid], sx[valid]] * (wy * wx)[valid]
    return centered


def prepare_image(image, crop_box=None, polarity="auto"):
    """Return the digit as a contiguous ``uint8`` array of shape ``(16, 16)``.

    ``image`` is a Pillow image, normally from :func:`load_image`. ``crop_box``
    is ``(left, top, right, bottom)`` in upright source-image pixels, with an
    exclusive right/bottom edge. It is applied before any pixel statistics.
    ``polarity`` describes the ink: ``dark``, ``light``, or ``auto`` (estimated
    from the border). Keep a small plain border around the digit for reliable
    background estimation; an incorrect automatic choice can be overridden.

    Subtract the estimated background, discard noise below 15% of peak ink,
    crop its bounding box, fit the aspect ratio within 12 x 12 pixels, then
    center by mass in a 16 x 16 frame. Inputs with less than 16/255 contrast or
    fewer than four visible foreground pixels are rejected. Grid lines and
    strong shadows can survive this simple threshold; use a clean export or
    a tighter crop. No digit classification occurs here.
    """
    if not isinstance(image, Image.Image):
        raise TypeError("image must be a Pillow Image; use load_image(path) first.")
    if polarity not in ("auto", "dark", "light"):
        raise ValueError("Polarity must be 'auto', 'dark', or 'light'.")
    selected = _crop(_upright_rgb(image), crop_box)
    gray = np.asarray(selected.convert("L"), dtype=np.float32)
    low, high = float(gray.min()), float(gray.max())
    if high - low < MIN_CONTRAST:
        raise ValueError("The image is blank or nearly uniform. Use a clear, contrasting digit.")

    # A thin border is less affected by an off-center digit than the whole image.
    border = np.concatenate((gray[0], gray[-1], gray[1:-1, 0], gray[1:-1, -1]))
    background = float(np.median(border))
    if polarity == "auto":
        polarity = "dark" if background >= (low + high) / 2.0 else "light"
    ink = background - gray if polarity == "dark" else gray - background
    peak = float(ink.max())
    if peak < MIN_CONTRAST:
        raise ValueError(
            "No contrasting digit found. Check ink polarity and include a plain border."
        )
    ink = np.clip(ink / peak, 0.0, 1.0)
    visible = ink > 0.15
    if np.count_nonzero(visible) < 4:
        raise ValueError("The image is blank or contains too little visible ink. Crop one clear digit.")
    ys, xs = np.nonzero(visible)
    ink[~visible] = 0.0
    ink = ink[ys.min():ys.max() + 1, xs.min():xs.max() + 1]

    height, width = ink.shape
    scale = INK_SIZE / max(height, width)
    new_width = max(1, int(round(width * scale)))
    new_height = max(1, int(round(height * scale)))
    resized = Image.fromarray((ink * 255).astype(np.uint8)).resize(
        (new_width, new_height), Image.Resampling.LANCZOS
    )
    canvas = np.zeros((TARGET_SIZE, TARGET_SIZE), dtype=np.float32)
    top, left = (TARGET_SIZE - new_height) // 2, (TARGET_SIZE - new_width) // 2
    canvas[top:top + new_height, left:left + new_width] = np.asarray(
        resized, dtype=np.float32
    ) / 255.0
    centered = _center_by_mass(canvas)
    return np.ascontiguousarray(np.clip(np.rint(centered * 256), 0, 255), dtype=np.uint8)
