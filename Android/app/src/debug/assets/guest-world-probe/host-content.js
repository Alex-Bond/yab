// This canary belongs to the host's ordinary extension world, never a guest world.
globalThis.__yabHostCanary = "host-only-canary";
browser.runtime.sendMessage({kind: "host-canary", storage: typeof browser.storage});
