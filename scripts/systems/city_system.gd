extends Node3D
## Base class for pluggable game systems (traffic, residents, economy...).
## main.gd creates every script listed in SYSTEMS and calls setup() once the
## city is loaded. A system gets the shared BuildingLibrary (meshes) and can
## read everything else from the CityData autoload (roads, objects, districts).
##
## To add a system: extend this file, override setup()/on_settings_changed(),
## and add its path to main.gd -> SYSTEMS.

var library


func setup(lib) -> void:
	library = lib


## Called when the graphics preset changes (e.g. to scale the number of agents).
func on_settings_changed() -> void:
	pass
