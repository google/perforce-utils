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

// The binary p4_storage_to_csv converts the journal representation of the db.storage table
// to CSV format.
package main

import (
	"bufio"
	"encoding/csv"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/golang/glog"
)

// The fields of the db.storage table are documented here:
// https://www.perforce.com/perforce/doc.current/schema/#db.storage.

const (
	DbStorageFieldRev        = 3
	DbStorageFieldType       = 4
	DbStorageFieldRefCount   = 5
	DbStorageFieldDigest     = 6
	DbStorageFieldSize       = 7
	DbStorageFieldServerSize = 8
	DbStorageFieldCompCksum  = 9
	DbStorageFieldDate       = 10
	DbStorageFieldLast       = 10
)

const (
	// Each journal entry has an entry type, version and table name, totaling 3 fields.
	// The db.storage table itself contains entry has 9 fields, so the journal total field count is 12.
	DbStorageJournalFieldCount = 12
	DbStorageFieldFileMarker   = 3
)

// https://www.perforce.com/perforce/doc.current/schema/#FileType
type ServerStorageType uint

const (
	RCSServerStorageType               ServerStorageType = 0x0
	BinaryServerStorageType                              = 0x1
	TinyServerStorageType                                = 0x2
	CompressedServerStorageType                          = 0x3
	TempObjServerStorageType                             = 0x4
	DetectServerStorageType                              = 0x5
	CompressedTempObjServerStorageType                   = 0x6
	BinaryAccessServerStorageType                        = 0x7
	ExternalServerStorageType                            = 0x8
)

type ServerStorageTypeModifier uint

const (
	Style992KeywordExpansionStorageTypeModifier   ServerStorageTypeModifier = 0x10
	Style20001KeywordExpansionStorageTypeModifier                           = 0x20
	AnyKeywordExpansionStorageTypeModifier                                  = 0x30
	ExclusiveOpenStorageTypeModifier                                        = 0x40
	NewTempObjStorageTypeModifier                                           = 0x40
)

type RevisionsNumber uint

const (
	S1RevisionsNumber   RevisionsNumber = 0x000
	S2RevisionsNumber   RevisionsNumber = 0x100
	S3RevisionsNumber   RevisionsNumber = 0x200
	S4RevisionsNumber   RevisionsNumber = 0x300
	S5RevisionsNumber   RevisionsNumber = 0x400
	S6RevisionsNumber   RevisionsNumber = 0x500
	S7RevisionsNumber   RevisionsNumber = 0x600
	S8RevisionsNumber   RevisionsNumber = 0x700
	S9RevisionsNumber   RevisionsNumber = 0x800
	S10RevisionsNumber  RevisionsNumber = 0x900
	S16RevisionsNumber  RevisionsNumber = 0xA00
	S32RevisionsNumber  RevisionsNumber = 0xB00
	S64RevisionsNumber  RevisionsNumber = 0xC00
	S128RevisionsNumber RevisionsNumber = 0xD00
	S256RevisionsNumber RevisionsNumber = 0xE00
	S512RevisionsNumber RevisionsNumber = 0xF00
)

type ClientStorageType uint

const (
	TextClientStorageType           ClientStorageType = 0x0
	BinaryClientStorageType                           = 0x10000
	ExecutableBitStorageType                          = 0x20000
	SymlinkClientStorageType                          = 0x40000
	ResourceForkClientStorageType                     = 0x50000
	UnicodeClientStorageType                          = 0x80000
	RawTextClientStorageType                          = 0x90000
	AppleData20022ClientStorageType                   = 0xC0000
	AppleData992ClientStorageType                     = 0xD0000
	DetectClientStorageType                           = 0x1000000
)

type ClientStorageTypeModifier uint

const (
	WritableClientStorageTypeModifier   ClientStorageTypeModifier = 0x100000
	ModTimeClientStorageTypeModifier                              = 0x200000
	UncompressClientStorageTypeModifier                           = 0x400000
)

type FileTypeBitMask uint

const (
	FileTypeBitMaskServerStorageType         FileTypeBitMask = 0xF
	FileTypeBitMaskServerStorageTypeModifier                 = 0xF0
	FileTypeBitMaskRevisionsNumber                           = 0xF00
	FileTypeBitMaskClientStorageType                         = 0x10D0000
	FileTypeBitMaskClientStorageTypeModifier                 = 0x720000
)

// Processes a Helix Core checkpoint or journal and verifies all files listed in the db.storage table
func processDbStorageEntries(journalPath string) error {
	file, err := os.OpenFile(journalPath, os.O_RDONLY, os.ModePerm)
	if err != nil {
		return fmt.Errorf("open file error: %v", err)
	}
	defer file.Close()

	fileCount := 0

	csvWriter := csv.NewWriter(os.Stdout)
	csvWriter.Write([]string{
		"LibrarianFile",
		"LibrarianRevision",
		"FileType",
		"ServerFileType",
		"ServerFileTypeModifier",
		"RevisionsNumber",
		"ClientFileType",
		"ServerFileModifier",
		"ReferenceCount",
		"MD5OfLibrarianFile",
		"FileSize",
		"FileSizeOnServer",
		"DigestOfCompressedFile",
		"LastUpdateDate"})

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

		filename := strings.Join(parts[DbStorageFieldFileMarker:DbStorageFieldFileMarker+filenameExtraPartCount], " ")
		filename = strings.Trim(filename, "@")

		revision := parts[DbStorageFieldRev+filenameExtraPartCount]
		fileType, err := strconv.ParseUint(parts[DbStorageFieldType+filenameExtraPartCount], 10, 64)
		if err != nil {
			glog.Warningf("WARNING: Could not parse file type: %v", parts[DbStorageFieldType+filenameExtraPartCount])
			continue
		}

		refCount, err := strconv.Atoi(parts[DbStorageFieldRefCount+filenameExtraPartCount])
		if err != nil {
			glog.Warningf("WARNING: Could not parse reference count: %v", parts[DbStorageFieldRefCount+filenameExtraPartCount])
			continue
		}

		digest := parts[DbStorageFieldDigest+filenameExtraPartCount]

		size, err := strconv.ParseInt(parts[DbStorageFieldSize+filenameExtraPartCount], 10, 64)
		if err != nil {
			glog.Warningf("WARNING: Could not parse size: %v", parts[DbStorageFieldSize+filenameExtraPartCount])
			continue
		}

		serverSize, err := strconv.ParseInt(parts[DbStorageFieldServerSize+filenameExtraPartCount], 10, 64)
		if err != nil {
			glog.Warningf("WARNING: Could not parse server size: %v", parts[DbStorageFieldServerSize+filenameExtraPartCount])
			continue
		}

		compCksum := parts[DbStorageFieldCompCksum+filenameExtraPartCount]

		date, err := strconv.Atoi(parts[DbStorageFieldDate+filenameExtraPartCount])
		if err != nil {
			glog.Warningf("WARNING: Could not parse date size: %v", parts[DbStorageFieldDate+filenameExtraPartCount])
			continue
		}

		serverFileType := ServerStorageType(fileType & uint64(FileTypeBitMaskServerStorageType))
		serverFileTypeModifier := ServerStorageTypeModifier(fileType & FileTypeBitMaskServerStorageTypeModifier)
		revisionsNumber := RevisionsNumber(fileType & FileTypeBitMaskRevisionsNumber)
		clientFileType := ClientStorageType(fileType & FileTypeBitMaskClientStorageType)
		clientFileTypeModifier := ClientStorageTypeModifier(fileType & FileTypeBitMaskClientStorageTypeModifier)

		csvWriter.Write([]string{
			filename,
			revision,
			strconv.FormatUint(fileType, 16),
			strconv.FormatInt(int64(serverFileType), 16),
			strconv.FormatInt(int64(serverFileTypeModifier), 16),
			strconv.FormatInt(int64(revisionsNumber), 16),
			strconv.FormatInt(int64(clientFileType), 16),
			strconv.FormatInt(int64(clientFileTypeModifier), 16),
			strconv.FormatInt(int64(refCount), 16),
			digest,
			strconv.FormatInt(size, 10),
			strconv.FormatInt(serverSize, 10),
			compCksum,
			strconv.FormatInt(int64(date), 10)})

		if err := csvWriter.Error(); err != nil {
			glog.Errorf("error writing csv:", err)
		}

		fileCount++
	}

	csvWriter.Flush()
	glog.Infof("Processed %v files\n", fileCount)

	return nil
}

func main() {
	// glog to both stderr and to file
	flag.Set("alsologtostderr", "true")

	flag.Parse()
	if flag.NArg() < 1 {
		glog.Errorf("Insufficient number or arguments specified")
		os.Exit(1)
	}

	start := time.Now()
	err := processDbStorageEntries(flag.Arg(0))
	if err != nil {
		glog.Errorf("Error processing storage entries: %v\n", err)
	}

	elapsed := time.Since(start)
	glog.Infof("Execution took %s\n", elapsed)

	if err != nil {
		os.Exit(1)
	}
}
