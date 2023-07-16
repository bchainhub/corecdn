# CORE CDN

This repository serves as a CDN (Content Delivery Network) for storing and deploying PNG and SVG image files. The images are organized in a specific folder structure, and you can access them through two different CDN URLs.

## Folder Structure and Path

The folder structure is as follows:

```
[badge/mark]/[png/svg]/[resolution]/{name}.[png/svg]
```

- **badge/mark**: This directory contains the badge or mark images.
- **png/svg**: Choose either the PNG or SVG directory based on the image format.
- **resolution**: This directory stores images of different resolutions. The resolution should be an integer value and can be one of the following options: 16, 32, 48, 64, 128, or 256.
- **{name}**: Replace this placeholder with the actual filename.

## CDN URLs

You can access the image files through the following CDN URLs:

1. **jsDelivr**: You can access the files using the URL: [https://cdn.jsdelivr.net/gh/cryptohub-digital/corecdn/{path}](https://cdn.jsdelivr.net/gh/cryptohub-digital/corecdn/{path}). Replace `{path}` with the path to the desired image file.

2. **corecdn.info**: Alternatively, you can also access the files using the URL: [https://corecdn.info/{path}](https://corecdn.info/{path}). Again, replace `{path}` with the path to the specific image file.

## Usage

To use the image files in your project, you can directly reference the URLs mentioned above. You can integrate these URLs into your web pages, apps, or any other platform that supports image rendering.

Here is an example of how you can use the CDN URLs in HTML:

```html
<img src="https://cdn.jsdelivr.net/gh/cryptohub-digital/corecdn/{path}" alt="Image Name">
```

Replace `{path}` with the actual path to the image file you want to display.

## Contributing

Contributions to this project are welcome. If you have any suggestions, improvements, or bug fixes, please open an issue to discuss them first. For major changes, it is recommended to discuss them beforehand.

Please make sure to update any relevant tests when contributing to this project.

## License

This software is licensed under the [CORE License](https://github.com/cryptohub-digital/core-license/blob/master/LICENSE).
