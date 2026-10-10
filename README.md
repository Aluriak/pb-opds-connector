# PocketBook OPDS Connector

An OPDS connector for PocketBook ebook readers. Manage connections to various OPDS providers.

**Features**

* **Browsing OPDS catalogs:**
  * Browse a default set of OPDS catalogs
    * Flibusta
    * ManyBooks
    * Gutenberg
    * Standard Ebooks
* **Format selection:** Choose the format you want, from the formats offered, showing a progress bar while downloading.

## Usage

1. Check the compatibility table below to find the platform of your device.
2. Download the matching archive from the [releases page](https://codeberg.org/codedge/pb-opds-connector/releases):
   `opds-connector-<version>-<platform>.zip` or `opds-connector-<version>-<platform>.zip`. Make sure you get the correct platform.
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

## Licence

See [LICENCE.md]
If you have a model, that is not tested yet, it would help a lot, if you can try out the connector.
After that please open an issue and report your findings, telling the model name and firmware version.
