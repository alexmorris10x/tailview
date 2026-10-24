# App icons

## App icon

The icon is drawn in [AppIcon.svg](AppIcon.svg): an iPad in landscape with the Mac pointer on it, on a violet background. Edit the SVG, then render the iOS and Mac icons (needs `rsvg-convert` and `magick` from Homebrew):

```sh
rsvg-convert -w 1024 -h 1024 docs/AppIcon.svg | magick - -background black -alpha remove -alpha off PNG24:IOSViewer/Assets.xcassets/AppIcon.appiconset/TailViewIcon.png

# Mac: the same art as an 824px rounded square with a soft shadow on a transparent 1024px canvas
T=$(mktemp -d)
rsvg-convert -w 824 -h 824 docs/AppIcon.svg -o $T/body.png
magick -size 824x824 xc:none -fill white -draw "roundrectangle 0,0 823,823 185,185" $T/m.png
magick $T/body.png $T/m.png -alpha off -compose CopyOpacity -composite $T/rounded.png
magick -size 1024x1024 xc:none \( $T/rounded.png -background black -shadow 40x12+0+12 \) -geometry +72+80 -composite $T/rounded.png -geometry +100+100 -composite $T/mac.png
for s in 16 32 64 128 256 512 1024; do magick $T/mac.png -resize ${s}x${s} MacHost/Assets.xcassets/AppIcon.appiconset/TailViewIcon-$s.png; done
```

Then regenerate the Dev icon below.

## Dev app icon

Debug uses the original app logo plus Memex's exact orange bottom DEV banner.
The banner is 230 pixels high on a 1024px icon, with centered white DEV text.
Release artwork and build identity are unchanged.

Regenerate from the original artwork with the shared [ios-dev-icons skill](https://github.com/alexmorris10x/10x-home/tree/main/.agents/skills/ios-dev-icons):

```sh
~/bin/ios-dev-icon --catalog IOSViewer/Assets.xcassets/AppIcon.appiconset IOSViewer/DevAssets.xcassets/AppIcon-Dev.appiconset
```

Append `--check` to verify every output. Commit generated PNGs; app builds do not require the helper.
