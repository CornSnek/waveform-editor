# Waveform Editor
App that draws and process audio waveforms and import/export as wavetables.

Created using the [Odin Programming Language](https://github.com/odin-lang/Odin)

## Installation
### Requirements
- Odin Programming Language
  - (Current version used: odin version dev-2026-08:8412dc37a)
- [Odin Imgui](https://gitlab.com/L-4/odin-imgui)
### Build Steps
```sh
# For Odin Imgui, follow the steps for your operating system to build the libraries.\
# To build the binary for this application
odin build . -collection:imgui=/path/to/odin-imgui/ -o:speed
```
Optionally, edit ols.json with the following for ols to work
```json
{
    "collections": [
        {
          "name": "imgui", "path": "/path/to/odin-imgui/"
        }
    ]
}
```
### Usage
I wanted to make a 'Waveform Editor' where I can draw waveforms. I was inspired by the NES audio expansion chipsets N163 and FDS, where custom waveforms can be drawn to make sounds. This program was created to also make waveforms other than just drawing them, and to 'Import/Export' the waveforms as integer values to create the wavetables for other NES music programs like FamiTracker or FamiStudio.

Other features added to this program:
- Importing waveforms from audio oscilloscope images.
- Importing waveforms from .wav files.
- Exporting waveforms as a whole .wav file, or in a directory of multiple .wav files each frame.
- Editing harmonics of a waveform.
- Editing waveforms with audio effects.
- Create waveforms and wavetables by Lua scripting.