# EditableImageBlur

```lua
type blurConfig = {
	image: EditableImage,
	pixelData: { number }?,
	blurRadius: number?,
	skipAlpha: boolean?,
	downscaleFactor: number?,
}
```

Simple usage example:

```lua
EditableImageBlur({
    image = EditableImage,
    blurRadius = 3,
})
```
