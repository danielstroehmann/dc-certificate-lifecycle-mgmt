@echo off
set PIV_TOOL="C:\Program Files\Yubico\Yubico PIV Tool\bin\yubico-piv-tool.exe"

set /p PIN="PIN: "

%PIV_TOOL% -averify-pin -P%PIN% -aset-chuid
