# Waveform Editor
App that imports, draws, exports audio waveforms and wavetables.

Created using the [Odin Programming Language](https://github.com/odin-lang/Odin)

## Installation
### Requirements
- Odin Programming Language
  - (Current version used: odin version dev-2026-07:301c287de)
- [Odin Imgui](https://gitlab.com/L-4/odin-imgui)
### Build Steps
```json
//For Odin Imgui, follow the steps for your operating system to build the libraries.
//Edit ols.json with the Odin Imgui path for ols to work
{
    "collections": [
        {
          "name": "imgui", "path": "/path/to/odin-imgui/"
        }
    ]
}
```
```sh
# In current project directory
odin build . -collection:imgui=/path/to/odin-imgui/ -o: speed
```
