# Waveform Editor
App that imports, draws, exports audio waveforms and wavetables.

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
odin build . -collection:imgui=/path/to/odin-imgui/ -o: speed
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
TODO
