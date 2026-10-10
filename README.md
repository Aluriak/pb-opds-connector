# PocketBook OPDS Connector

An OPDS connector for PocketBook e-readers. Browse catalogs and download books straight to the device.

**Features**

* **Native PocketBook integration:** Built on PocketBook's own SDK, so it looks and behaves like the reader's built-in apps.
* **Browsing OPDS catalogs:**
  * Calibre and custom endpoints (coming soon)
  * Browse a default set of OPDS catalogs
    * Flibusta
    * ManyBooks
    * Gutenberg
    * Standard Ebooks
* **Format selection:** Choose from the formats a catalog offers. A progress bar shows the download.
* **Download handling:** Books are saved to the Downloads folder and show up in the library right away, without a restart.

## Usage

1. Check the compatibility table below to find the platform of your device.
2. Download the matching archive from the [releases page](https://codeberg.org/codedge/pb-opds-connector/releases):
   `opds-connector-<version>-<platform>.zip`. Make sure you get the correct platform.
3. Unzip it and copy `OPDS Connector.app` into the `applications` folder of your reader.
4. Open "OPDS Connector" from the applications list on the reader.

## Compatibility

Only firmware 6.x is supported. Anything older is not supported and will not work.

| Firmware | Platform | Devices | Status |
|---|---|---|---|
| 6.11 | `allwinner` | Era Lite (PB710) | ✅ Tested |
| 6.x | `allwinner` | Allwinner B288 models: Era, InkPad 4, InkPad Lite, Verse, Verse Pro, Touch HD 3 | ❔ Untested, expected to work |
| 6.x | `allwinner` | Allwinner B300 models: Era Color, Verse Pro Color, InkPad Color 2/3, InkPad X Pro | ❔ Untested |
| 6.11 | `rk3566` | Rockchip RK3566 models: Verta, Verta Color, InkPad One, PocketBook Q | ❔ Untested, expected to work |

If your model is not tested yet, it would help a lot if you tried the connector and opened an issue with your findings, including the model name and firmware version.

## Contributing

Contributions are welcome. Please open an issue first, describing the problem along with your firmware version and model. If you already have a fix, open a pull request with tests.

## Licence

See [LICENCE.md](LICENCE.md).
