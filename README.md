<img src="icon.png" width="80" align="right" alt="">

# BTRename

Give Bluetooth devices nicknames on iOS 6, shown in Settings, the audio pickers and the call screen. The device keeps its real name.

## Features

- Rename any Bluetooth device from its page in Settings › Bluetooth.
- The nickname shows in the Bluetooth list and on the device page, in the audio and AirPlay pickers (app switcher, lock screen, apps) and in the in-call audio list.
- Display only: the device keeps its real name, and other tweaks still see the real name, so Ultimate AirPods Fix keeps working.

## How to use

1. Settings › Bluetooth › tap the blue arrow next to a device › Rename.
2. Type a nickname and tap Save. Empty the box or tap Use Real Name to undo.

## Requirements

- Jailbroken iOS 6 (tested on an iPhone 5 with iOS 6.1.2)
- Cydia Substrate (Cydia installs them for you)

## Install

In Cydia, add `https://mbucc9000.github.io/slopkit/` and install **BTRename**. Or download the `.deb` from [Releases](../../releases) and install it with `dpkg -i`.

## Building

[Theos](https://theos.dev) with the iOS 6.1 SDK: `make package FINALPACKAGE=1`.

## License

MIT.
