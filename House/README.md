# Saved play rooms

Both play spaces are backed up in this private repository:

| Room | Files |
| --- | --- |
| Original play room | This folder's `house.usdz`, `structure.json`, `worldmap.arexperience`, and `rooms/` |
| Main | [`SavedRooms/969A274E-DF9F-4119-9770-16808C7A5668`](SavedRooms/969A274E-DF9F-4119-9770-16808C7A5668) |

Main was copied from Bok's saved room library on October 24, 2026. Its room ID,
name, model, structure, individual room scan, and complete AR world map are
preserved together. The original scan remains unchanged.

The current app loads this folder as an Xcode folder resource. Pull the repo,
build the app, and open **Host a game → Play room** to choose an interior. The
updated room library includes both spaces and works offline. The host sends the
selected map's fingerprint so joining phones load the same included map. Update
all phones before playing in a newly added room.

This is a repository backup included at build time, not a live download from
GitHub. The app does not contain GitHub credentials. Adding another room to the
repository requires a new app build to make it available on every phone.

To add another backup, copy the complete `Documents/SavedRooms/<UUID>/` folder
from the scanning phone into `House/SavedRooms/`. Keep the original UUID and
`room-info.json`; do not mix files from different scans. New local scans are
still saved on the phone until explicitly backed up here.

## Scan contents

The RoomPlan + ARKit scan of the play space, copied from the Documents/House folder of the iPhone that scanned it (same layout `HouseStore` reads and writes):

- `worldmap.arexperience`: ARKit world map, used to relocalize in the real house
- `structure.json`: merged RoomPlan structure (walls, doors, objects)
- `house.usdz`: merged 3D model
- `rooms/room-1.json`: each room as scanned

The world map only works in the physical place it was scanned. This repository is private; keep it that way while this folder is in it.
