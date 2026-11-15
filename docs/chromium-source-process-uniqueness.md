# Native source metadata process uniqueness

Partial decoder hardening only. In one current whole native frame tree, different logical RenderProcessHost instances cannot claim the same OS PID, even if their birth/incarnation metadata conflicts. The decoder now retains a bounded OS-PID-to-logical-instance map alongside the existing logical process, native incarnation and context checks; any conflict refuses the entire metadata object. Repeated frames from the SAME logical/native process still share one witness description. No OS PID is used for signal/query authority.

Two controlled production-decoder Swift methods are authored NOT_RUN: duplicate original PID/birth with separate native incarnations, conflicting birth for the same PID, legitimate shared actual process across two frames, and distinct valid processes. Default source/caller policies, private factory, full NativePhase and commit flags unchanged0/unavailable. No runtime/build/job or source SDK/cache mutation.
