# Third party sources

The application uses libusb 1.0 through its C API. The USB protocol implementation
was written for this project with reference to the following public implementations:

- https://github.com/superna9999/pyamlboot/tree/d2857f4371bcdb7a90d885f24987e03b6d647a8a
  Protocol, read/write framing and status acknowledgements. Apache-2.0 OR MIT in
  pyamlboot.py; GPL-2.0 OR MIT in optimus.py. Reference under the MIT option.
- https://github.com/idootop/open-xiaoai/tree/bc3396c64e2a435f354eb5cb12a203981f1fe422
  LX06 firmware workflow and OTA patch locations. MIT.
- https://github.com/duhow/xiaoai-patch
  Read as a reference for partition layout. Its implementation is not included.
- https://github.com/yangfl/amlogic-update
  Read as a reference for the USB command format. Its implementation is not included.

The app bundles unmodified Homebrew SquashFS tool executables with relocated
dynamic-library paths. It does not bundle the legacy Amlogic update executable.
Packaged component versions, source archive URLs, hashes and license notices are
in Contents/Resources/Licenses. libusb and the compression libraries remain
dynamically linked and can be replaced and the local app re-signed.

- libusb: https://github.com/libusb/libusb, LGPL-2.1-or-later
- squashfs-tools: https://github.com/plougher/squashfs-tools, GPL-2.0-or-later
- lzo: https://www.oberhumer.com/opensource/lzo/, GPL-2.0-or-later
- lz4: https://github.com/lz4/lz4, BSD-2-Clause (library)
- xz/liblzma: https://github.com/tukaani-project/xz, see bundled notices
- zstd: https://github.com/facebook/zstd, BSD-3-Clause OR GPL-2.0

Original LX06 firmware is downloaded separately from the upstream release and is
verified against its pinned SHA-256. Xiaomi firmware is not included in this app's
source code or application bundle. Firmware patches preserve the existing
filesystem metadata and are applied locally.
