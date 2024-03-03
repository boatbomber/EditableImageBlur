# EditableImageBlur

Fast blurring for Roblox EditableImage

## Installation

Via [wally](https://wally.run):

```toml
[dependencies]
EditableImageBlur = "boatbomber/editableimageblur@0.1.0"
```


## Usage

Package returns a single function.

```lua
function EditableImageBlur(blurConfig: {
	image: EditableImage, -- The EditableImage to use
	pixelData: { number }?, -- Pixel data array, for applying blur to an image data that isn't yet written into the EditableImage
	blurRadius: number?, -- Radius of the gaussian blur
	skipAlpha: boolean?, -- Whether to skip blurring the alpha channel
	downscaleFactor: number?, -- Downscaling can help make it run faster for minimal loss in quality (ddownscaling won't apply if pixelData is passed)
})

```

Simple usage example:

```lua
local EditableImageBlur = require(Packages.EditableImageBlur)

EditableImageBlur({
    image = EditableImage,
    blurRadius = 3,
})
```
