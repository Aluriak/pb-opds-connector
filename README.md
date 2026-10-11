# PocketBook OPDS Connector

An OPDS connector for PocketBook e-readers. Browse catalogs and download books straight to the device.

**Features**

* **Native PocketBook integration:** Built on PocketBook's own SDK, so it looks and behaves like the reader's built-in apps.
* **Browsing OPDS catalogs:**
  * [Calibre and custom endpoints](#configuration)
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

## Configuration

### Custom server

Besides the built-in catalogs you can add your own OPDS servers, for example Calibre or Calibre-Web.

1. Open "+ Add server" at the end of the start screen.
2. Fill in the form and leave it with the back button. The server then appears in the list.

| Field | Required | Notes |
|---|---|---|
| Name | yes | What the server is called in the list. |
| URL | yes | For example `192.168.1.20:8080`. |
| User name | no | Leave empty if the server needs no login. |
| Password | no | Only used together with a user name. |

**What happens to the URL**

* Without `http://` or `https://` in front, `http://` is added.
* Without a path, `/opds` is added, which is where Calibre serves its catalog. `192.168.1.20:8080` becomes `http://192.168.1.20:8080/opds`. If your catalog is somewhere else, type the full URL including the path.
* A URL with a path is kept as you typed it.

**When nothing is saved**

* If the name or the URL is empty, the form closes without saving. There is no message.
* If the URL is not a valid address, the app shows "Could not save the server".

**Edit or delete a server**

Press and hold a server you added, then choose "Edit" or "Delete". The built-in catalogs cannot be changed.

**About the login**

* The user name and password are stored unencrypted on the reader, in `system/config/opds-connector.cfg`. Anyone with access to the reader's storage can read them.
* They are only sent to the server you entered, never to another server a catalog links to.

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
