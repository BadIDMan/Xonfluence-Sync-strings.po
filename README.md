# Xonfluence-Sync-strings.po
Powershell script for synchronizing strings.po content across all languages strings.po files

What does the Xonfluence PO synchronization script do?
Script synchronizes all Xonfluence language strings.po files with the English source file: resource.language.en_gb\strings.po
The English file is treated as the authoritative source for the available message IDs, their order, msgid values and the footer.

For every language file, the script:
- creates a backup of the original strings.po as strings-backup.po when backup is enabled;
- reads the English source file but never modifies it;
- synchronizes the target language file using the English file as the template;
- preserves the target language's existing translations (msgstr) for all message IDs that already exist;
- adds message IDs that are present in English but missing from the target language, with an empty msgstr;
- removes message IDs that no longer exist in the English source;
- updates the target msgid to match the English source when the text of an existing message has changed;
- keeps the entries in exactly the same order as the English source;
- preserves the target language's PO header;
- removes obsolete/custom comments from the target file;
- copies the current footer from the English source to the synchronized file;
- ensures that the footer is added only once and is not duplicated.

The script also reports the synchronization results for each language, including the number of entries kept, added, removed and changed.

More details and how to use: https://forum.kodi.tv/showthread.php?tid=384448&pid=3306502#pid3306502
