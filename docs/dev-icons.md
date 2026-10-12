# Dev app icon

Debug uses the original app logo plus Memex's exact orange bottom DEV banner.
The banner is 230 pixels high on a 1024px icon, with centered white DEV text.
Release artwork and build identity are unchanged.

Regenerate from the original artwork with the shared [ios-dev-icons skill](https://github.com/alexmorris10x/10x-home/tree/main/.agents/skills/ios-dev-icons):

```sh
~/bin/ios-dev-icon --catalog IOSViewer/Assets.xcassets/AppIcon.appiconset IOSViewer/DevAssets.xcassets/AppIcon-Dev.appiconset
```

Append `--check` to verify every output. Commit generated PNGs; app builds do not require the helper.
