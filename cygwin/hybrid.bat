: <<'BASH_PORTION'
@goto batch
BASH_PORTION

# export
export DIR_CLOUD="D:/.gradle/OneDrive"

# aliases
alias ee="ee.bat"
alias src="cd ${DIR_CLOUD}"
alias src="cd ${DIR_SOURCE}"
alias set="cd ${DIR_SETTING}"
alias pro="cd ${DIR_PROGRAM}"
alias misc="cd ${DIR_MISC}"
alias np="D:/.gradle/Onedrive/_MyProgram/_IDEditor/Notepad++/notepad++.exe"
alias bc="D:/.gradle/OneDrive/_MyProgram/_FileBrowser/_BC/Bcompare.exe"
alias find="D:/.gradle/OneDrive/_MyProgram/_Shell/_Gnutool/bin/find.exe"
alias term="D:/.gradle/OneDrive/_MyProgram/_Shell/_Cygwin/bin/mintty.exe"

: <<'BATCH_PORTION'
:batch
@echo off
for /f "tokens=2* delims== " %%I in (
    'findstr "^alias" "%~f0"'
) do (
    ::echo %%J
    set "T=%%J"
    call set "T=%%T:/=\%%"
    ::call echo %%T%%
    doskey %%~I=%%T%%
)

for /f "tokens=2* delims== " %%I in (
    'findstr "^export" "%~f0"'
) do set %%~I=%%~J
exit /b
BATCH_PORTION
