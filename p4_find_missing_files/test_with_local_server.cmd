@echo off

@REM =============================================================================================
@REM Copyright 2021 Google Inc.
@REM 
@REM Licensed under the Apache License, Version 2.0 (the "License");
@REM you may not use this file except in compliance with the License.
@REM You may obtain a copy of the License at
@REM 
@REM https://www.apache.org/licenses/LICENSE-2.0
@REM 
@REM Unless required by applicable law or agreed to in writing, software
@REM distributed under the License is distributed on an "AS IS" BASIS,
@REM WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
@REM See the License for the specific language governing permissions and
@REM limitations under the License.
@REM =============================================================================================

@REM =============================================================================================
@REM 
@REM Use the standalone p4d server on Windows to test p4_find_missing_files.
@REM 
@REM =============================================================================================

@REM Save the current directory
pushd .

@REM Create a first standalone Perforce server under %TEMP%\p4fmf
rmdir /s /q %temp%\p4fmf
cd /d %temp%
mkdir p4fmf
cd %temp%\p4fmf
echo P4PORT=rsh:c:\Program Files\Perforce\DVCS\p4d.exe -r %temp%\p4fmf -i > .p4config
set P4CONFIG=.p4config

@REM Convert to Unicode
set P4CHARSET=utf8
"c:\Program Files\Perforce\DVCS\p4d.exe" -xi
p4 depots

@REM Create a client and generate some changes
mkdir client
cd client
p4 client -o | p4 client -i
mkdir path1
cd path1

echo "DATA1" > README.txt
p4 add README.txt
fsutil file createnew data1.dat 10485760
p4 add data1.dat
fsutil file createnew data2.dat 10485760
p4 add data2.dat

p4 submit -d "Initial files"

p4 edit README.txt
echo "DATA Edited" > README.txt
p4 edit data1.dat
del data1.dat
fsutil file createnew data1.dat 10485760

p4 submit -d "Second change"

cd ..
mkdir path2
cd path2 

echo "MORE DATA" > More.txt
p4 add More.txt
p4 submit -d "Third change"

@REM Create a checkpoint
p4 admin checkpoint

echo "Test data created under %TEMP%\p4fmf"

@REM Go back to the original directory
popd
