# UI localization

Spacebar 3D follows macOS's language preference, including a language selected for the app in System Settings. English is the fallback. The app and Quick Look support English, Simplified Chinese, Spanish, French, German, Japanese, Brazilian Portuguese, Korean, Italian and Russian.

The shared catalog is `Packages/Spacebar3DKit/Sources/ModelCore/Resources/Localizable.xcstrings`. `L10n.text` resolves static UI text from that package's resource bundle. `L10n.format` inserts string arguments into translated `%@` placeholders. Use complete sentences for notices; do not assemble translated nouns and verbs. Use locale-aware number formatting before inserting numbers.

Keep file names, model-authored animation names, format identifiers, persisted setting values, license texts and the Spacebar 3D name unchanged. Third-party parser or operating-system diagnostic details may use the language supplied by that component; the app's surrounding error messages are translated.

When adding UI text, add the English key and all nine translations to the catalog and use `L10n` at the source. The catalog is manually managed because it is shared across several modules. Generated Swift symbols are disabled per entry to allow distinct English keys that differ only in capitalization or punctuation. Keep `CFBundleLocalizations` in both targets in `project.yml` aligned with the catalog. Run XcodeGen after editing that file.

Run `python3 scripts/check-localizations.py` to check source-key coverage, translation states and format placeholders. `ModelCoreTests/LocalizationTests` checks the compiled resources for every language, actual language-specific lookups and literal insertion of file names containing percent characters. Use the full Xcode test scheme for regression checks.

For layout checks, exercise the welcome page, Settings, Help, viewer bars, material and light popovers, and missing-file notices in languages with longer labels. Test both the standalone app and Quick Look resource packaging. Changing a SwiftUI locale environment alone does not change Foundation bundle language selection; launch with the intended app language for end-to-end verification.

The viewer bar uses a menu for the view selector when translated segments do not fit the available width. Settings actions sit below their explanatory text so long labels have a full row. Light and material popovers allow extra width.

## Documentation translations

The English README stays at the repository root. Each other supported language has
`docs/<language-code>/README.md`: `zh-Hans`, `es`, `fr`, `de`, `ja`, `pt-BR`, `ko`,
`it` and `ru`. Every README links to all ten versions. Keep setup requirements,
signing instructions, format limitations, controls, folder-access behavior and
license credits aligned with the English source.

The English development guide is `docs/DEVELOPMENT.md`. Its nine translations are
at `docs/<language-code>/DEVELOPMENT.md`. Each README links to its matching guide.
Other supporting documents are not all translated.

From a translated README, shared images and documentation are one level up in
`docs`, while repository-root files use `../../`. Section links use explicit ASCII
anchors so translated headings can change without breaking navigation.

When changing the development guide, update all nine translations in the same
change. Preserve shell commands, paths, identifiers, version pins and explicit
ASCII section anchors. Match quoted app controls to the string catalog. Check
relative links from the language folder and compare fenced command blocks with
the English source. Language navigation must include all ten guides.
