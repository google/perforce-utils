/*
Copyright 2021 Google Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// The binary p4_find_missing_files scans Perforce checkpoints/journals and verifies
// that all files are present in the depot.
// It is meant as a quick alternative to the very slow "p4 verify" and,
// unlike "p4 verify", it doesn't check md5 hashes.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/golang/glog"
	"github.com/karrick/godirwalk"
)

// https://www.perforce.com/perforce/doc.current/schema/#FileType
type ServerStorageType int

const (
	RCSStorageType          ServerStorageType = 0
	BinaryStorageType                         = 1
	TinyStorageType                           = 2
	CompressedStorageType                     = 3
	TempObjStorageType                        = 4
	DetectTypeStorageType                     = 5
	CompressedTempObj                         = 6
	BinaryAccessStorageType                   = 7
	ExternalStorageType                       = 8
)

const (
	// Each journal entry has an entry type, version and table name, totaling 3 fields.
	// The db.storage entry has 9 fields per https://www.perforce.com/perforce/doc.current/schema/#db.storage.
	DbStorageJournalFieldCount = 12
)

func registerExistingPath(filemap map[string]int, value string, caseSensitive bool) {
	valueToAdd := value
	if !caseSensitive {
		valueToAdd = strings.ToLower(value)
	}
	filemap[valueToAdd] = 1
	glog.V(2).Infof("%v added to filemap\n", valueToAdd)
}

func pathExistsOnDisk(filemap map[string]int, value string, caseSensitive bool) bool {
	var exists bool
	if caseSensitive {
		_, exists = filemap[value]
	} else {
		_, exists = filemap[strings.ToLower(value)]
	}

	return exists
}

// Scans an RCS file for revisions and adds file+revision pairs to the filemap
func readVersionsFromRCS(filePath string, normalizedPath string, filemap map[string]int, caseSensitive bool) error {

	file, err := os.OpenFile(filePath, os.O_RDONLY, os.ModePerm)
	if err != nil {
		return fmt.Errorf("error opening RCS file %v: %v", filePath, err)
	}
	defer file.Close()

	var sentinelBuffer = [...]string{"text", "@@", "log"}

	var circularBuffer [4]string
	bufferPosition := 0

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		circularBuffer[bufferPosition] = line
		bufferPosition = (bufferPosition + 1) % len(circularBuffer)
		if line == "text" {
			testIndex := bufferPosition - 1
			if testIndex < 0 {
				testIndex = len(circularBuffer) - 1
			}
			scanIndex := 0
			for scanIndex < len(sentinelBuffer) && circularBuffer[testIndex] == sentinelBuffer[scanIndex] {
				scanIndex++
				testIndex--
				if testIndex < 0 {
					testIndex = len(circularBuffer) - 1
				}
			}
			if scanIndex == len(sentinelBuffer) {
				registerExistingPath(filemap, normalizedPath+"/"+circularBuffer[testIndex], caseSensitive)
			}
		}
	}

	return nil
}

// Lists all versioned files under a depot path, optionally scoping the scan to the subdirectory specified by filter
func listVersionedFiles(depotPath string, filter string, caseSensitive bool) (map[string]int, error) {
	filemap := make(map[string]int)
	rootPath := depotPath
	if len(filter) > 0 {
		rootPath = filepath.Join(depotPath,
			strings.ReplaceAll(strings.Trim(filter, "/"), "/", string(filepath.Separator)))
	}
	err := godirwalk.Walk(rootPath, &godirwalk.Options{
		Callback: func(osPathname string, de *godirwalk.Dirent) error {
			if de.IsDir() {
				return nil
			}
			// Normalized the path:
			// 1. Strip depot path from osPathname
			// 2. Ensure backslashes are converted to forward slashes - Perforce depot paths always use forward slashes
			// 3. Trim any leading or trailing slashes
			// 4. Prefix with // to make the path depot-absolute
			normalizedPath := "//" + strings.Trim(strings.ReplaceAll(strings.Replace(osPathname, depotPath, "", 1), "\\", "/"), "/")
			if strings.HasSuffix(normalizedPath, ",v") {
				if err := readVersionsFromRCS(osPathname, normalizedPath, filemap, caseSensitive); err != nil {
					return fmt.Errorf("Error reading versions from RCS file: %v", err)
				}
			} else {
				registerExistingPath(filemap, normalizedPath, caseSensitive)
			}
			return nil
		},
		Unsorted: true, // we don't need sorting and this is faster
	})
	return filemap, err
}

// Processes a Helix Core checkpoint or journal and verifies all files listed in the db.storage table
func processDbStorageEntries(journalPath string, filemap map[string]int, filter string, caseSensitive bool) error {
	file, err := os.OpenFile(journalPath, os.O_RDONLY, os.ModePerm)
	if err != nil {
		return fmt.Errorf("open file error: %v", err)
	}
	defer file.Close()

	fileCount := 0
	missingCount := 0

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		parts := strings.Split(line, " ")
		if len(parts) < 4 {
			continue
		}
		if parts[0] != "@pv@" {
			continue
		}
		if parts[2] != "@db.storage@" {
			continue
		}

		// The filename is the only part of the line that may contain spaces.
		// That means that if a filename contained spaces, we'd have more fields than expected.
		// We can find how many pieces the filename has been split into by computing the difference.
		filenameExtraPartCount := len(parts) - DbStorageJournalFieldCount

		filename := strings.Join(parts[3:3+filenameExtraPartCount], " ")
		filename = strings.Trim(filename, "@")
		if len(filter) > 0 && !strings.HasPrefix(filename, filter) {
			continue
		}
		revision := parts[3+filenameExtraPartCount]
		fileType, err := strconv.Atoi(parts[4+filenameExtraPartCount])
		if err != nil {
			glog.Warningf("WARNING: Could not parse file type: %v", parts[4+filenameExtraPartCount])
			continue
		}

		serverFileType := ServerStorageType(fileType & 0xF)
		var versionedFilePath string

		glog.V(2).Infof("%v [%v] (%v - %v) scanned\n", filename, revision, fileType, serverFileType)

		if serverFileType == RCSStorageType {
			versionedFilePath = filename + ",v/" + revision[1:len(revision)-1]
		} else {
			versionedFilePath = filename + ",d/" + revision[1:len(revision)-1]
		}

		exists := pathExistsOnDisk(filemap, versionedFilePath, caseSensitive)
		if !exists {
			exists = pathExistsOnDisk(filemap, versionedFilePath+".gz", caseSensitive)
			if !exists {
				missingCount++
				glog.Warningf("Missing %v", versionedFilePath)
			}
		}

		fileCount++
	}

	glog.Infof("Processed %v files\n", fileCount)
	glog.Infof("Missing %v files\n", missingCount)

	return nil
}

func main() {
	// glog to both stderr and to file
	flag.Set("alsologtostderr", "true")

	flags := struct {
		caseSensitive bool
		verbose       bool
		filter        string
	}{}

	flag.BoolVar(&flags.caseSensitive, "case-sensitive", false, "Case-sensitive processing.")
	flag.BoolVar(&flags.verbose, "verbose", false, "Verbose output.")
	flag.StringVar(&flags.filter, "filter", "", "Prefix filter to narrow the scanning path.")

	flag.Parse()
	if flag.NArg() < 2 {
		glog.Errorf("Insufficient number or arguments specified")
		os.Exit(1)
	}

	if flags.verbose {
		flag.Set("v", "2")
	}

	glog.V(2).Infoln("Starting p4_find_missing_files in verbose mode")

	start := time.Now()
	filemap, _ := listVersionedFiles(flag.Arg(1), flags.filter, flags.caseSensitive)
	err := processDbStorageEntries(flag.Arg(0), filemap, flags.filter, flags.caseSensitive)
	if err != nil {
		glog.Errorf("Error processing storage entries: %v\n", err)
	}

	elapsed := time.Since(start)
	glog.Infof("Execution took %s\n", elapsed)

	if err != nil {
		os.Exit(1)
	}
}
