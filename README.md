# PocketBook OPDS Connector (fork)

> **This is a personal fork. The original project is
> [codedge/pb-opds-connector](https://codeberg.org/codedge/pb-opds-connector) on Codeberg, by
> codedge, who wrote the app and keeps developing it. Use it unless you need something below.**
>
> This fork exists to try out features for my own reader before they reach the original, if they
> ever do. Its changes were written with the help of an AI assistant (Claude); the original
> project does not take AI-written code, so they are not sent there as pull requests. Bugs found
> here are reported to the original as issues, without code.
>
> What the fork adds, on top of an older version of the original:
>
> * Synchronizing a whole list (e.g. a Calibre-Web shelf) to the reader, see [Synchronization](#synchronization)
> * Per-server settings: sending the login right away (Calibre-Web), connection timeout
> * The default catalogs stored in the settings file, editable and removable
> * Error messages that say why a request failed
> * The name of the catalog in the header
> * Self-updates from the [nightly release](https://github.com/Aluriak/pb-opds-connector/releases/tag/nightly), see [Updates](#updates)
>
> It misses what the original added since, among others mobi, azw3 and txt downloads and the
> HTTP/1.1 setting for catalogs behind bot protection.
>
> Bugs of the fork belong here, not to the original. All credit for the app goes to codedge;
> the [licence](LICENCE.md) is the original MIT licence.

An OPDS connector for PocketBook e-readers. Browse catalogs and download books straight to the device.

**Features**

* **Native PocketBook integration:** Built on PocketBook's own SDK, so it looks and behaves like the reader's built-in apps.
* **Browsing OPDS catalogs:**
  * [Calibre and custom endpoints](#configuration)
  * A default set of OPDS catalogs, which you can edit or delete like your own
    * Flibusta
    * ManyBooks
    * Gutenberg
    * Standard Ebooks
* [**Synchronization:**](#synchronization) Download all books of a list (a Calibre-Web shelf, for example) that are not on the reader yet, in one go.
* [**Updates:**](#updates) The app can update itself from its GitHub releases, when you ask for it.
* [**Search:**](#search) Catalogs that offer a search show a "Search" row at the top of each list.
* **Format selection:** Choose from the formats a catalog offers. A progress bar shows the download.
* **Download handling:** Books are saved to the Downloads folder and show up in the library right away, without a restart.

## Usage

1. Check the compatibility table below to find the platform of your device.
2. Download the matching archive of this fork from the [nightly release](https://github.com/Aluriak/pb-opds-connector/releases/tag/nightly):
   `opds-connector-<platform>.zip`. Make sure you get the correct platform.
   For the original app, see its [releases page](https://codeberg.org/codedge/pb-opds-connector/releases).
3. Unzip it and copy `OPDS Connector.app` into the `applications` folder of your reader.
4. Open "OPDS Connector" from the applications list on the reader.

## Configuration

### Custom server

Besides the default catalogs you can add your own OPDS servers, for example Calibre or Calibre-Web.

1. Open "+ Add server" at the end of the start screen.
2. Fill in the form and leave it with the back button. The server then appears in the list.

| Field | Required | Notes |
|---|---|---|
| Name | yes | What the server is called in the list. |
| URL | yes | For example `192.168.1.20:8080`. |
| User name | no | Leave empty if the server needs no login. |
| Password | no | Only used together with a user name. |
| Calibre-Web | no | Choose "Yes" for Calibre-Web. The login is then sent right away, instead of after a first try without it, which Calibre-Web counts as a failed login (it allows three a minute). |
| Allow full sync | no | Lists of books of this catalog get a "Synchronize" row, see [Synchronization](#synchronization). |
| Connection timeout | no | Seconds to wait for the server to answer the connection, 5 when empty. Raise it for a slow or distant server. |

**What happens to the URL**

* Without `http://` or `https://` in front, `http://` is added.
* Without a path, `/opds` is added, which is where Calibre serves its catalog. `192.168.1.20:8080` becomes `http://192.168.1.20:8080/opds`. If your catalog is somewhere else, type the full URL including the path.
* A URL with a path is kept as you typed it.

**When nothing is saved**

* If the name or the URL is empty, the form closes without saving. There is no message.
* If the URL is not a valid address, the app shows "Could not save the server".

**Edit or delete a server**

Press and hold a server, then choose "Edit" or "Delete". This works for the default catalogs too. Once deleted, they do not come back.

### Configuration file

All servers, the default catalogs included, are stored in `system/config/opds-connector.cfg` on the reader. You can prepare or edit it on a computer while the reader is connected over USB, instead of typing the servers on the reader:

```
defaults_added=1
server.0.name=Calibre-Web
server.0.url=http://192.168.1.20:8083/opds/
server.0.user=alice
server.0.password=secret
server.0.calibre_web=1
server.0.timeout=30
server.0.sync=1
server.1.name=Project Gutenberg
server.1.url=https://www.gutenberg.org/ebooks.opds/

#…
```

* The numbers start at 0 and must follow each other. The list ends at the first missing number.
* `user`, `password`, `calibre_web`, `timeout` and `sync` can be left out.
* `updates=` sets which updates the app offers, see [Updates](#updates). The URL rules above apply here as well.
* Without `defaults_added=1` the default catalogs are put in front of your servers on the next start, and the line is added.
* The app rewrites the file whenever you add, edit or delete a server on the reader, from the list it loaded at start. Close the app completely (also in the task switcher) before editing the file, or your changes are overwritten.
* **The last line, like `#f78a2ef5`, is a checksum** the reader adds when it saves the file. If it does not match the content, the reader silently uses the previous version, `opds-connector.cfg.back`, and your changes are lost. After editing the file, fix the checksum with `python3 scripts/fix-config-checksum.py opds-connector.cfg`.

**About the login**

* The user name and password are stored unencrypted on the reader, in [the configuration file](#configuration-file). Anyone with access to the reader's storage can read them.
* They are only sent to the server you entered, never to another server a catalog links to.

### Language

The app speaks English or French. By default it follows the reader's language; the last row of
the start screen switches between the reader's language, French and English. The choice is kept
in the configuration file as `language=auto`, `fr` or `en`.

## Synchronization

For a server with "Allow full sync" set to "Yes", every list of books starts with a "Synchronize" row (after "Search", if there is one). Opening it loads the whole list, then downloads each book that is not on the reader yet, in EPUB if the catalog offers it. A summary tells how many were downloaded, already there or failed.

* Books are recognized by the id the catalog gives them, not by title or author, so a book renamed in the catalog is not downloaded again. Calibre and Calibre-Web give every book such an id.
* They are saved in the Downloads folder as `<author> - <title>.<tag>.epub`, e.g. `Jean Hegland - Le Temps d'après.3f2a9c41b07de815.epub`. The tag comes from the book's id and is how the sync finds the book again, so leave it in the name. When a title or author changes in the catalog, the next sync renames the file. Books you download by hand from such a server get the same kind of name, so a sync does not fetch them a second time.
* Books already in the Downloads folder under another name, for example copied over USB, are taken over instead of downloaded again: a file with the format and the exact size the catalog gives, and the title in its name, is renamed like a synchronized book. Calibre-Web gives the size of each file; a catalog that does not cannot be matched this way.
* At the end, the sync looks for files in the Downloads folder that are exact copies, byte for byte, of a synchronized book, and offers to delete them. The synchronized book stays, and so does your reading progress: the reader recognizes a book by its content.
* Books that left the list since its last synchronization are listed at the end, and the sync offers to delete them from the reader. Only books synchronized from this very list count, and not those another synchronized list still holds. Whether you delete or keep them, they are not asked about again. Which books came from which list is kept in `system/config/opds-connector-sync.tsv`.
* Nothing else is deleted or replaced without asking: a book whose file changed in the catalog is not downloaded again.
* The progress bar has a button to stop the sync after the book being downloaded. A stopped sync deletes nothing. Open "Synchronize" again to go on: what is already on the reader is skipped.

## Search

Many catalogs can be searched. If a catalog offers this, every list inside it starts with a "Search" row.

1. Open the "Search" row.
2. Type what you are looking for and confirm.
3. The results open as a new list. From there you can download books, open sub-lists or search again. The back button returns to the list you came from.

**Good to know**

* The search is done by the catalog, not by the app. What is searched (titles, authors, descriptions) and how the results are sorted depends on the catalog. Some catalogs, like Flibusta, first ask whether you want to search books or authors.
* A catalog without a search has no "Search" row. The start screen has none either: there is no search across all catalogs at once.
* If nothing matches, the app shows "Nothing found." and stays on the current list.
* This also works for servers you added yourself, as long as they offer a search. Calibre and Calibre-Web do.


## Updates

Builds from the [GitHub releases](https://github.com/Aluriak/pb-opds-connector/releases) can update themselves. The last row of the start screen, "Check for updates", shows the installed version.

1. Open "Check for updates". The app looks for a newer build.
2. If there is one, it shows its version, whether it is a release or a nightly build, and asks whether to install it.
3. After "Install", close the app and open it again.

Two kinds of builds are offered:

* **Releases**: versions that were tagged, offered when their version number is higher than the installed one.
* **Nightly builds**: built from every change to the code, offered when they were built from another change than the installed one. They are newer, and less tested.

Choose what is offered with a line in [the configuration file](#configuration-file):

| Line | Effect |
|---|---|
| `updates=stable` | Releases only. This is the default. |
| `updates=all` | Releases and nightly builds, which are made from every change and less tested. |
| `updates=off` | No "Check for updates" row. |

If an update does not start, copy the app onto the reader by hand again, as when installing it.

**Versions of the fork** continue from 0.3.1, the version of the original it started from:
0.3.2, 0.3.3… They have nothing to do with the versions of the original (0.4.0, 0.5.0…).

**Publishing a release** (for maintainers): set the new version in `build.zig.zon` and push it to `main`. The build workflow sees that this version has no release yet and publishes one, tagged `v<version>`. Pushing such a tag by hand works too.

## Debugging

The app shows why a request failed: the HTTP status the server answered with, or what went wrong before an answer came. For more, use a debug build, which writes a log:

1. Download `opds-connector-<platform>-debug.zip` from the [nightly release](https://github.com/Aluriak/pb-opds-connector/releases/tag/nightly), or build it yourself with `zig build -Dplatform=<platform>`.
2. Copy `OPDS Connector.bin` and `opds-debug.app` into the `applications` folder of the reader.
3. Open "opds-debug" from the applications list instead of "OPDS Connector".
4. The log is written to `opds-log.txt` at the top of the reader's storage.

The log shows every request in detail, including the login header. That header holds the password in a readable form, so remove it before you share a log.

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
