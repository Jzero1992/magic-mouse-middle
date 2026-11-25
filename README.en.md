# Magic Mouse Middle

[简体中文](README.md)

Add an adjustable middle-click zone to your Apple Magic Mouse. Press the center of the touch surface with one finger to send a middle click. By default, conversion applies only when DaVinci Resolve is in front.

## Install and use

1. Download the app ZIP from [Releases](../../releases), extract it, and move the app to Applications.
2. Open the app. Click its mouse icon in the macOS menu bar and choose **Enable Permissions…**. Follow the system prompts for Accessibility and Input Monitoring.
3. Choose **Settings…** from the same menu. Drag the slider to resize the zone, then click the mouse diagram to check which button the app received.
4. In the Resolve Color page, select the destination clip. Hover over the graded source clip and press the center of the Magic Mouse to apply its grade.

The release includes Apple silicon and Intel builds and requires macOS 13 or later. The app reads touch positions using a private macOS interface, which may change in future system updates. If an update leaves the app reporting missing permissions even though they appear enabled in System Settings, choose **Reset Permissions…**, reopen the app, and grant permissions again.

## Change the interface language

Click the mouse icon in the menu bar and choose **Language / 语言**, then **English** or **简体中文**. The change takes effect immediately and is saved for the next launch. On first launch, the app chooses Simplified Chinese or English based on the preferred macOS language.

## Build from source

Install the Xcode command-line tools, then run:

```sh
./build.sh
"./Magic Mouse 中键.app/Contents/MacOS/MagicMouseMiddle" --self-test
```

## License

Design and copyright © J.zero. The source code is available under the [MIT License](LICENSE).
