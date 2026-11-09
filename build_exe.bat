@echo off
cd /d "%~dp0"
python -m pip install --upgrade nuitka ordered-set zstandard
python -m nuitka --onefile --windows-console-mode=disable --include-package=pystray --output-dir=dist --output-filename=ActivityTracker.exe --remove-output tracker.py
if errorlevel 1 (echo BUILD FAILED & exit /b 1)
echo Built: %~dp0dist\ActivityTracker.exe
