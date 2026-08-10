# EditableImageBlur

Fast Gaussian-approximating blur for Roblox `EditableImage` pixel buffers.

[Please consider supporting my work.](https://github.com/sponsors/boatbomber)

![demo-video](./assets/blur-demo.mp4)

## Installation

Via [wally](https://wally.run):

```toml
[dependencies]
EditableImageBlur = "boatbomber/editableimageblur@1.0.0"
```

## Usage

This is a pure buffer-manipulation library: it never touches an `EditableImage` itself.
Read the pixels, blur the buffer in place, and write it back:

```lua
local EditableImageBlur = require(Packages.EditableImageBlur)

local pixels = editableImage:ReadPixelsBuffer(Vector2.zero, editableImage.Size)

EditableImageBlur.Blur({
  pixelBuffer = pixels,
  width = editableImage.Size.X,
  height = editableImage.Size.Y,
  blurRadius = 3,
})

editableImage:WritePixelsBuffer(Vector2.zero, editableImage.Size, pixels)
```

### API

```lua
EditableImageBlur.Blur(config: BlurConfig): ()
EditableImageBlur.BlurAsync(config: BlurAsyncConfig): ()
```

Both blur `config.pixelBuffer` in place and return nothing.

- `Blur` is synchronous and never yields; the result is ready on return, in the same frame.
- `BlurAsync` splits the image into row bands and blurs them on an internal actor pool (parallel Luau), so it may yield. Its output is bit-identical to `Blur`. Falls back to the synchronous path when necessary.
- Overlapping `BlurAsync` calls are isolated from each other, but two concurrent calls over the same buffer have unspecified ordering. Serialize per buffer if you stream blurs.

```lua
type BlurConfig = {
  pixelBuffer: buffer, -- u8 RGBA pixel data, row-major; modified in place
  width: number, -- image width in pixels
  height: number, -- image height in pixels
  blurRadius: number?, -- sigma of the gaussian blur (default 2)
  skipAlpha: boolean?, -- leave the alpha channel untouched (default false)
  downscaleFactor: number?, -- (0, 1]: blur a downsampled copy for speed and
  -- upsample back on completion (default 1); great for large images since
  -- the blur hides the lost detail anyway
}

type BlurAsyncConfig = BlurConfig & {
  workerCount: number?, -- parallel workers to split the image across (default 6)
  syncThreshold: number?, -- images with fewer working pixels than this blur
  -- synchronously (default 256 * 256)
}
```
