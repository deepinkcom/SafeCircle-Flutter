# Android launcher icon

The circular variant uses `neon_guardian_shield_original.png`, preserved byte
for byte from the second upload. The manifest's `android:roundIcon` references
`@mipmap/ic_launcher_round`. Five legacy round PNGs and five adaptive round
foregrounds are generated from the complete 1254px image, without cropping.
The adaptive round resource uses the same navy background and 66dp artwork
placement as the square variant, retaining the neon rim inside the circle mask.
Android launchers decide whether to use the roundIcon or the default icon;
some circular masks may still be applied to the default artwork.

`neon_shield_community_original.png` is the uploaded PNG preserved byte for byte.
It is a design source, not a Flutter runtime asset; no pubspec registration or
launcher-icon package is required.

Regenerate on Windows from the repository root:

```powershell
powershell -NoProfile -File tools/generate_android_icons.ps1
```

The script uses Windows System.Drawing with bicubic resampling. It trims only
fully transparent outer pixels, preserves aspect ratio and centers the artwork.
The five legacy PNGs are 48, 72, 96, 144 and 192 pixels, with 4% padding per side
and an opaque navy (#070D35) background.

Android 8.0+ uses `mipmap-anydpi-v26/ic_launcher.xml`: a solid navy background
and transparent foregrounds at 108, 162, 216, 324 and 432 pixels. The complete
tile occupies 66dp of the 108dp layer. The shield, people, bell and orbit remain
within the central safe region; launcher masks can trim decorative tile corners.
No monochrome layer is supplied because this detailed full-color artwork is
not a suitable monochrome silhouette.

The manifest continues to reference `@mipmap/ic_launcher`, so resource selection
automatically uses legacy icons below API 26 and adaptive icons from API 26.
Other platforms and in-app imagery are unchanged. Review circle and rounded
square masks, then check the icon on a device after installing a fresh build;
some launchers cache an older installed icon.
