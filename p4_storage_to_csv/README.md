# Converts the db.storage journal entries to CSV

This tool converts the db.storage jhournal text-based entries to CSV format that can be imported into a
relational database such as sqlite to simplify analysis.

Please note that while it will work on any journal/checkpoint, it's more efficient to use it on files
that only contain db.storage entries.

For example, the following command will extract storage-related entries from a Prod checkpoint:

```
grep "@db.storage@" /opt/journal/checkpoints/commit.ckp.123 > ~/storage.txt
```

## Installation

```
go get github.com/google/perforce-utils/p4_storage_to_csv
```

## Running the tool

Simply run the tool from the command-line, passing in the path to the journal.
The CSV outputs to the standard output, so you'd want to redirect to a file.

For example:

```
p4_storage_to_csv example_journal.txt > example_journal.csv
```

Note: this assumes that your Go bin folder is in your PATH (for example, ~/go/bin on Linux).

You can import the resulting file into SQLite3 for subsequent analysis.

For example:

```
sqlite3 -csv storage.db ".import example_journal.csv DbStorage"
```
