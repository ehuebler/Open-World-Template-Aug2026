"""Build the instanced giant flower tree.

Run from the repository root:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" `
        --background --factory-startup `
        --python blender_assets/source/build_flower_tree.py

The implementation lives in :mod:`flower_tree_asset` so the deterministic
geometry, PNG paint, GLB validation and preview renderer can also be imported by
asset tooling without executing a build on import.
"""

import os
import sys

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
if SOURCE_DIR not in sys.path:
    sys.path.insert(0, SOURCE_DIR)

from flower_tree_asset import main


if __name__ == "__main__":
    main()
