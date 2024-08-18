# EditableImageBlur

Fast blurring for Roblox EditableImage.

[Please consider supporting my work.](https://github.com/sponsors/boatbomber)

*Blur Radius 1*
![image](https://github.com/boatbomber/EditableImageBlur/assets/40185666/12735c3f-c81b-4c4e-ae7c-e1258cb7ff2d)
*Blur Radius 5*
![image](https://github.com/boatbomber/EditableImageBlur/assets/40185666/baa961cb-045e-4e19-a32a-5612a9f330f9)
*Blur Radius 15*
![image](https://github.com/boatbomber/EditableImageBlur/assets/40185666/3bc1203e-0e3a-40b3-a67e-f53eb039b38f)

## Installation

Via [wally](https://wally.run):

```toml
[dependencies]
EditableImageBlur = "boatbomber/editableimageblur@0.3.2"
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
