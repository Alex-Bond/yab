#!/usr/bin/env python3
"""The parts of the Mac's sources that SyncShapes.swift needs and that build
without AppKit, cut out as they are: Session's Entry, Pair and Shape, and the
SyncChats enum (without its SyncCenter extension).

    extract.py Sources/Fast OUT_DIR
"""
import pathlib
import sys

src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)

session = (src / "Session.swift").read_text()
start = session.index("enum Session {")
end = session.index("    /// The first space's is the session")
(out / "SessionTypes.swift").write_text("import Foundation\n\n" + session[start:end] + "}\n")

chats = (src / "SyncChats.swift").read_text()
(out / "SyncChatsCore.swift").write_text(chats[: chats.index("// MARK: - The Mac's side")])
print("extracted", sorted(p.name for p in out.iterdir()))
