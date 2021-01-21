# Lightweight tool to find missing Perforce files

The "p4 verify" command allows finding missing and corrupt files on a Helix Core server.
However, it is very slow because it verifies the MD5 hash of every file, meaning that running
it against the entire repository can take many hours or even days.

The distributed Helix Core environment presents a number of issues where files might not replicate.
In those cases, we are only interested in missing files and we don't need to check file integrity.

This tool does exactly that:

- It lists all the available versioned files 
- It then reads a Helix checkpoint or journal and verifies that all known files (from db.storage table)
  are present.

It supports both binary and RCS files.

Additional context:
https://forums.perforce.com/index.php?/topic/6806-verifying-missing-files-only/

## Installation

```
go get github.com/google/perforce-utils/p4_find_missing_files
```

## Running the tool

```
p4_find_missing_files JOURNAL_PATH DEPOT_ROOT
```

Options:

-case-sensitive turns case sensitivity on (it's off by default)

-filter allows to specify a depot path prefix

-verbose turns verbose logging on

Note: this assumes that your Go bin folder is in your PATH (for example, ~/go/bin on Linux).

## Checking the tool functionality (Windows):

```
test_with_local_server.cmd
go run p4_find_missing_files.go -case-sensitive -filter=//depot/path1 -verbose %temp%\p4fmf\checkpoint.1 %temp%\p4fmf
```
