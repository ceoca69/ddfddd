# Read-folder container patch

This patch changes only the Airlift read path logic in `rust-core/src/exploit.rs`.

## Changes

1. **Source-scoped AssetID for `/var/mobile/...` reads**
   - `/var/mobile/Containers/Data/Application/<UUID>` is represented as:
     `../../<unique-airlift-source>/../../Containers/Data/Application/<UUID>`
   - This keeps the resolved destination the same while making the Books/AirTraffic Persistent ID unique to the current read session.

2. **AFC materialization polling**
   - After the final `FileComplete`, the code now waits up to 4 seconds for the recovered object to actually appear through AFC.
   - The read/folder enumerator no longer immediately races `FileComplete` completion.

3. **Diagnostics**
   - Logs the exact source-scoped AssetID.
   - Logs when the recovered object becomes visible and its AFC type.

No UI, Scan Apps, PosterBoard logic, or write-path logic was changed.
