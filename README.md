# FlasherPro

A Windows desktop utility for common Android Fastboot firmware workflows.

## Features

- **Platform Tools** — open a command prompt in the Platform Tools directory.
- **Firmware Unpacker** — extract ZIP-based firmware packages into a selected directory.
- **Firmware Flasher** — inspect image files, select partitions, review commands, and flash selected images through Fastboot.
- **Windows builds** — build and package the application through GitHub Actions.

## Requirements

- Windows 10 or later
- A device with an unlocked bootloader when required by the firmware
- USB debugging/bootloader drivers installed as appropriate
- A compatible firmware package for your exact device and model
- Platform Tools are included in release packages built by the workflow

## Build locally

Install the stable Flutter SDK and enable Windows desktop support.

```powershell
flutter config --enable-windows-desktop
flutter pub get
flutter build windows --release
```

The executable is produced under `build/windows/x64/runner/Release/`.

## Notes

Flashing firmware can erase data or make a device unbootable if images are incompatible. Confirm the device model, firmware version, partition names, and active Fastboot mode before flashing. The application does not lock the bootloader or format user data automatically.

## License

See [LICENSE](LICENSE).
