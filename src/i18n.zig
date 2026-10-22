//! The texts of the app, in English and French.

const std = @import("std");

pub const Lang = enum {
    en,
    fr,

    /// The language for a reader language code ("fr", "fr_FR", "en", ...)
    pub fn fromCode(code: []const u8) Lang {
        return if (std.ascii.startsWithIgnoreCase(code, "fr")) .fr else .en;
    }
};

/// What the user picked: follow the reader, or one of the languages
pub const Choice = enum {
    auto,
    en,
    fr,

    pub fn parse(text: []const u8) Choice {
        return std.meta.stringToEnum(Choice, std.mem.trim(u8, text, " \t\r\n")) orelse .auto;
    }

    pub fn next(choice: Choice) Choice {
        return switch (choice) {
            .auto => .fr,
            .fr => .en,
            .en => .auto,
        };
    }

    pub fn resolve(choice: Choice, reader_code: []const u8) Lang {
        return switch (choice) {
            .auto => Lang.fromCode(reader_code),
            .en => .en,
            .fr => .fr,
        };
    }
};

/// The language texts are given in
pub var lang: Lang = .en;

/// Every text, first in English, then in French. Texts with {} take arguments, see `fmt`.
const texts = .{
    .app_title = .{ "OPDS Connector", "Connecteur OPDS" },
    .add_server = .{ "+ Add server", "+ Ajouter un serveur" },
    .add_server_detail = .{ "Calibre or another OPDS server", "Calibre ou un autre serveur OPDS" },
    .search = .{ "Search", "Rechercher" },
    .search_detail = .{ "Search this catalog", "Rechercher dans ce catalogue" },
    .sync = .{ "Synchronize", "Synchroniser" },
    .sync_detail = .{ "Download all books of this list that are not on the reader yet", "Télécharger les livres de cette liste absents de la liseuse" },
    .nothing_to_open = .{ "Nothing to open for this entry.", "Rien à ouvrir pour cette entrée." },
    .nothing_found = .{ "Nothing found.", "Aucun résultat." },
    .edit = .{ "Edit", "Modifier" },
    .delete = .{ "Delete", "Supprimer" },
    .cancel = .{ "Cancel", "Annuler" },
    .keep = .{ "Keep", "Garder" },
    .delete_server = .{ "Delete this server?", "Supprimer ce serveur ?" },
    .save_server_error = .{ "Could not save the server", "Impossible d'enregistrer le serveur" },
    .open_catalog_error = .{ "Could not open the catalog", "Impossible d'ouvrir le catalogue" },
    .search_error = .{ "Could not search the catalog", "Impossible de chercher dans le catalogue" },
    .load_more_error = .{ "Could not load more entries", "Impossible de charger la suite" },
    .load_all_error = .{ "Could not load the whole list", "Impossible de charger toute la liste" },
    .sync_error = .{ "Could not synchronize", "Impossible de synchroniser" },
    .download = .{ "Download", "Télécharger" },
    .download_error = .{ "Could not download the book", "Impossible de télécharger le livre" },
    .downloading = .{ "Downloading", "Téléchargement" },
    .saved = .{ "Saved to Downloads:\n{s}", "Enregistré dans Downloads :\n{s}" },
    .synchronizing = .{ "Synchronizing", "Synchronisation" },
    .sync_done = .{ "{s}Synchronized: {d} downloaded, {d} already on the reader{s}{s}, {d} failed{s}", "{s}Synchronisé : {d} téléchargé(s), {d} déjà sur la liseuse{s}{s}, {d} en échec{s}" },
    .sync_stopped = .{ "Stopped before the end. ", "Arrêtée avant la fin. " },
    .removed_found = .{
        "{s}\n\nA synchronized book left this list:{s}{s}\n\nDelete it from the reader?",
        "{s}\n\nUn livre synchronisé n'est plus dans cette liste :{s}{s}\n\nLe supprimer de la liseuse ?",
    },
    .removed_found_many = .{
        "{s}\n\n{d} synchronized books left this list:{s}{s}\n\nDelete them from the reader?",
        "{s}\n\n{d} livres synchronisés ne sont plus dans cette liste :{s}{s}\n\nLes supprimer de la liseuse ?",
    },
    .removed_deleted = .{ "Books deleted: {d}.", "Livres supprimés : {d}." },
    .sync_renamed = .{ " ({d} renamed)", " ({d} renommé(s))" },
    .sync_adopted = .{ ", {d} found under another name", ", {d} trouvé(s) sous un autre nom" },
    .sync_skipped = .{ ", some books have no id and were left out.", ", des livres sans identifiant ont été laissés de côté." },
    .copy_found = .{
        "{s}\n\nA file in Downloads is an exact copy of a synchronized book:{s}{s}\n\nDelete the copy? The synchronized books and your reading progress stay.",
        "{s}\n\nUn fichier de Downloads est une copie exacte d'un livre synchronisé :{s}{s}\n\nSupprimer la copie ? Les livres synchronisés et votre progression de lecture restent.",
    },
    .copies_found = .{
        "{s}\n\n{d} files in Downloads are exact copies of synchronized books:{s}{s}\n\nDelete the copies? The synchronized books and your reading progress stay.",
        "{s}\n\n{d} fichiers de Downloads sont des copies exactes de livres synchronisés :{s}{s}\n\nSupprimer les copies ? Les livres synchronisés et votre progression de lecture restent.",
    },
    .copies_deleted = .{ "Copies deleted: {d}.", "Copies supprimées : {d}." },
    .login_refused = .{ "The server refused the login (HTTP {d}). Check the user name and password.", "Le serveur a refusé l'identifiant (HTTP {d}). Vérifiez le nom d'utilisateur et le mot de passe." },
    .not_found = .{ "Nothing found at this address (HTTP 404). Check the URL.", "Rien à cette adresse (HTTP 404). Vérifiez l'URL." },
    .http_error = .{ "The server answered with an error (HTTP {d}).", "Le serveur a répondu par une erreur (HTTP {d})." },
    .curl_error = .{ "curl error {d}", "erreur curl {d}" },
    .form_error = .{ "Could not open the form", "Impossible d'ouvrir le formulaire" },
    .form_add = .{ "Add server", "Ajouter un serveur" },
    .form_edit = .{ "Edit server", "Modifier le serveur" },
    .field_name = .{ "Name", "Nom" },
    .field_url = .{ "URL", "URL" },
    .field_user = .{ "User name (optional)", "Nom d'utilisateur (facultatif)" },
    .field_password = .{ "Password (optional)", "Mot de passe (facultatif)" },
    .field_calibre_web = .{ "Calibre-Web (send the login right away)", "Calibre-Web (envoyer l'identifiant d'emblée)" },
    .field_timeout = .{ "Connection timeout in seconds (optional)", "Délai de connexion en secondes (facultatif)" },
    .field_sync = .{ "Allow full sync", "Autoriser la synchronisation complète" },
    .no = .{ "No", "Non" },
    .yes = .{ "Yes", "Oui" },
    .language = .{ "Language: {s}", "Langue : {s}" },
    .language_auto = .{ "same as the reader", "celle de la liseuse" },
    .language_change = .{ "English or French", "Français ou anglais" },
    .language_title = .{ "Language", "Langue" },
    .current_choice = .{ "Current choice", "Choix actuel" },
    .language_en = .{ "English", "English" },
    .language_fr = .{ "Français", "Français" },
};

pub const Key = std.meta.FieldEnum(@TypeOf(texts));

/// A text without arguments
pub fn t(comptime key: Key) [:0]const u8 {
    const pair = @field(texts, @tagName(key));
    return switch (lang) {
        .en => pair[0],
        .fr => pair[1],
    };
}

/// A text with arguments, written into `buf`
pub fn fmt(buf: []u8, comptime key: Key, args: anytype) [:0]const u8 {
    const pair = @field(texts, @tagName(key));
    const text = switch (lang) {
        .en => std.fmt.bufPrintSentinel(buf, pair[0], args, 0),
        .fr => std.fmt.bufPrintSentinel(buf, pair[1], args, 0),
    };
    return text catch "…";
}

/// A text with arguments, allocated
pub fn alloc(allocator: std.mem.Allocator, comptime key: Key, args: anytype) ![:0]const u8 {
    const pair = @field(texts, @tagName(key));
    return switch (lang) {
        .en => std.fmt.allocPrintSentinel(allocator, pair[0], args, 0),
        .fr => std.fmt.allocPrintSentinel(allocator, pair[1], args, 0),
    };
}

test "every text exists in both languages with the same arguments" {
    inline for (@typeInfo(@TypeOf(texts)).@"struct".field_names) |name| {
        const pair = @field(texts, name);
        try std.testing.expectEqual(2, pair.len);
        try std.testing.expectEqual(std.mem.count(u8, pair[0], "{"), std.mem.count(u8, pair[1], "{"));
    }
}

test "texts follow the chosen language" {
    defer lang = .en;
    lang = .fr;
    try std.testing.expectEqualStrings("Rechercher", t(.search));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Copies supprimées : 2.", fmt(&buf, .copies_deleted, .{2}));
    try std.testing.expectEqual(Lang.fr, Choice.auto.resolve("fr_FR"));
}
