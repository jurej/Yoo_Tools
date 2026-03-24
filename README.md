# Slope Overlay (SketchUp Extension)

Repository root folder: **`Yoo_Tools`**.

## Features

- **Slope overlay**: Shows the slope of the face under your mouse cursor:
  - **Angle (°)** relative to horizontal (0° = flat, 90° = vertical)
  - **Grade (%)** where \(grade = \tan(angle) \times 100\)
- **Align to Axis (Coplanar)**: Moves vertices from selected faces/edges onto a plane through a picked anchor vertex, perpendicular to a chosen axis (world, current model axes, or local group axes). Optional colinear loop simplification and soft-edge dissolve between coplanar faces.

## Requirements

- SketchUp **2019+**

## Install (manual)

1. Close SketchUp.
2. From the **`Yoo_Tools`** repo folder, copy `yoo_tools.rb` and the `yoo_tools/` folder into your SketchUp Plugins directory:
   - Windows (typical): `%AppData%\SketchUp\SketchUp 20XX\SketchUp\Plugins`
3. Start SketchUp.

## Use

### Slope overlay

- **Plugins → Slope Overlay** (or **Yoo_Tools** context submenu) toggles the overlay tool on/off.
- Hover over a face or edge to see slope.

### Align to axis

1. Select one or more **faces** and/or **edges** (same group/component context for **Local group** frame).
2. **Plugins → Align to Axis (Coplanar)** or **Yoo_Tools → Align to Axis (Coplanar)**.
3. Adjust options (see overlay near cursor):
   - **Frame**: **World**, **Local group**, or **Current axes** (model axes). Use **[** / **]** or arrow keys to cycle.
   - **Axis**: **X**, **Y**, **Z**, or **A** for **Closest** (pick axis most aligned with average face normals). Keys **X Y Z A**.
   - **K**: toggle **Colinear cleanup** (default on): simplifies outer/inner loops with tolerance `1e-4` model units; rebuilds faces when possible.
   - **E**: toggle **Stray edges**: dissolves **soft** edges between two **coplanar** faces (common interior partitions).
4. **Click** a vertex to use as the **anchor** (plane passes through it). One undo step for the whole operation.

If colinear rebuild fails for a face, the operation **aborts** and the model rolls back (nothing partially applied).

### Limitations

- Locked or mixed nested contexts: geometry is skipped or **Local group** may be unavailable (warning in overlay).
- Complex holes, non-planar results, or invalid loops after move can cause rebuild failure (undo restores).

## Development

- Run RuboCop (optional but recommended):
  - `gem install rubocop rubocop-sketchup`
  - `rubocop`
