# Waveform Editor
App that draws and process audio waveforms and import/export as wavetables.

Created using the [Odin Programming Language](https://github.com/odin-lang/Odin)

## Installation
### Requirements
- Odin Programming Language
  - (Current version used: odin version dev-2026-07:301c287de)
- [Odin Imgui](https://gitlab.com/L-4/odin-imgui)
### Build Steps
```sh
# For Odin Imgui, follow the steps for your operating system to build the libraries.\
# To build the binary for this application
odin build . -collection:imgui=/path/to/odin-imgui/ -o:speed
```
```json
//Optionally, edit ols.json with the following for ols to work
{
    "collections": [
        {
          "name": "imgui", "path": "/path/to/odin-imgui/"
        }
    ]
}
```
### Usage
I wanted to make my own 'Waveform Editor' where I can import waveforms and wavetables from .wav files or oscilloscope images of audio. I was inspired by the NES audio expansion chipsets N163 and FDS, where waveforms where custom waveforms can be drawn to make music.

There is an 'Import/Export Text' option that can get the integer values to create the wavetables for other NES music programs like FamiTracker or FamiStudio.