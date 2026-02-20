# CORE CDN

This repository serves as a CDN (Content Delivery Network) for storing and deploying PNG and SVG image files. The images are organized in a specific folder structure, and you can access them through two different CDN URLs.

## Actions

- [Open repository page](https://github.com/bchainhub/corecdn)
- [Fork repository](https://github.com/bchainhub/corecdn/fork)
- [Open issue](https://github.com/bchainhub/corecdn/issues)

## Click&Copy

> Modify the example link as needed

```url
https://corecdn.info/mark/256/xcb.png
```

## Folder Structure and Path

Source assets are **SVG files** in the `base` folder. A script generates multiple sizes in both SVG and PNG from these sources.

```txt
[badge|mark]/base/{name}.svg         ← source (SVG only)
[badge|mark]/[size]/{name}.svg       ← generated
[badge|mark]/[size]/{name}.png       ← generated
```

- **badge/mark**: Top-level directory for badge or mark images.
- **base**: Contains the source SVG files. Only SVGs live here; PNGs are generated.
- **size**: Generated output folders named by pixel size (see list below).
- **{name}**: The filename without extension.

### Generated sizes

The script produces icons at these pixel sizes (in both SVG and PNG):

**16**, **24**, **32**, **48**, **64**, **72**, **96**, **128**, **144**, **192**, **256**, **512**, **1024**

## Build script

The script `scripts/resize_icons.sh` generates all size variants from the base SVGs:

1. Finds every SVG under `badge/base/` and `mark/base/`.
2. For each base SVG, creates a folder per size (e.g. `mark/256/`) and:
   - Copies the SVG into that folder.
   - Exports a PNG at that pixel size using Inkscape.

**Requirements:** [Inkscape](https://inkscape.org/) must be installed and on your `PATH`.

**Run from the repo root:**

```bash
./scripts/resize_icons.sh
```

After running, commit the updated `badge/<size>/` and `mark/<size>/` folders as needed.

## CDN URLs

You can access the image files through the following CDN URLs:

1. **jsDelivr**: You can access the files using the URL: [https://cdn.jsdelivr.net/gh/bchainhub/corecdn/{path}](https://cdn.jsdelivr.net/gh/bchainhub/corecdn/{path}). Replace `{path}` with the path to the desired image file.

2. **corecdn.info**: Alternatively, you can access the files using the URL: [https://corecdn.info/{path}](https://corecdn.info/{path}). Replace `{path}` with the path to the specific image file.

## Usage

To use the image files in your project, you can directly reference the URLs mentioned above. You can integrate these URLs into your web pages, apps, or any other platform that supports image rendering.

Here's an example of how you can use the CDN URLs in HTML:

```html
<img src="https://cdn.jsdelivr.net/gh/bchainhub/corecdn/{path}" alt="Image Name">
```

Replace `{path}` with the actual path to the image file you want to display.

## Contributing

Contributions to this project are welcome. If you have any suggestions, improvements, or bug fixes, please open an issue to discuss them first. For major changes, it is recommended to discuss them before implementing.

Please make sure to update any relevant tests when contributing to this project.

## License

This software is licensed under the [CORE License](https://github.com/bchainhub/core-license/blob/master/LICENSE).
