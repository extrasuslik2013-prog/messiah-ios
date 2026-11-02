@echo off
rem Builds Updater.exe (Messiah Updater) into updater\dist
cd /d "%~dp0"
python -m pip install --quiet pyinstaller zeroconf || exit /b 1
python -m PyInstaller --noconfirm --clean --onefile --windowed --name Updater ^
  --icon messiah.ico --add-data "messiah.ico;." --collect-submodules zeroconf messiah_updater.py
echo Built: %~dp0dist\Updater.exe
