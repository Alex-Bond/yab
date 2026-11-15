// An origin's localStorage and IndexedDB as JSON text, read on one engine and
// written on the other (EngineStorageCarry.swift). It runs in an empty document
// at that origin, one call at a time, so nothing of the site's is running. The
// text crosses in parts: the helper's wire takes 4 MB at most.
(async function (call) {
  const carry = globalThis.__yabCarry || (globalThis.__yabCarry = {text: ''});

  const encode64 = bytes => {
    let text = '';
    for (let at = 0; at < bytes.length; at += 0x8000) text += String.fromCharCode.apply(null, bytes.subarray(at, at + 0x8000));
    return btoa(text);
  };
  const decode64 = text => Uint8Array.from(atob(text), letter => letter.charCodeAt(0));

  // Structured clone's values as JSON. What can't cross (a CryptoKey, a class
  // instance, a cycle) throws, and that one record stays behind.
  const encode = async (value, path) => {
    if (value === undefined) return {$: 'u'};
    if (value === null || typeof value === 'boolean' || typeof value === 'string') return value;
    if (typeof value === 'number') return Number.isFinite(value) && !Object.is(value, -0) ? value : {$: 'n', v: String(value)};
    if (typeof value === 'bigint') return {$: 'i', v: String(value)};
    if (typeof value !== 'object' || path.includes(value)) throw new TypeError('not cloneable');
    const deeper = [...path, value];
    if (value instanceof Date) return {$: 'd', v: value.getTime()};
    if (value instanceof RegExp) return {$: 'r', v: value.source, f: value.flags};
    if (value instanceof ArrayBuffer) return {$: 'b', v: encode64(new Uint8Array(value))};
    if (ArrayBuffer.isView(value)) {
      return {$: 't', n: value.constructor.name, v: encode64(new Uint8Array(value.buffer, value.byteOffset, value.byteLength))};
    }
    if (value instanceof Blob) {
      return {$: 'B', t: value.type, n: value.name ?? null, m: value.lastModified ?? null,
              v: encode64(new Uint8Array(await value.arrayBuffer()))};
    }
    if (value instanceof Map) {
      const rows = [];
      for (const [key, item] of value) rows.push([await encode(key, deeper), await encode(item, deeper)]);
      return {$: 'm', v: rows};
    }
    if (value instanceof Set) {
      const rows = [];
      for (const item of value) rows.push(await encode(item, deeper));
      return {$: 's', v: rows};
    }
    if (Array.isArray(value)) {
      const rows = [];
      for (const item of value) rows.push(await encode(item, deeper));
      return rows;
    }
    const shape = Object.getPrototypeOf(value);
    if (shape !== Object.prototype && shape !== null) throw new TypeError('not cloneable');
    const fields = {};
    for (const key of Object.keys(value)) fields[key] = await encode(value[key], deeper);
    return '$' in fields ? {$: 'o', v: fields} : fields;
  };
  const decode = value => {
    if (Array.isArray(value)) return value.map(decode);
    if (value === null || typeof value !== 'object') return value;
    switch (value.$) {
      case 'u': return undefined;
      case 'n': return Number(value.v);
      case 'i': return BigInt(value.v);
      case 'd': return new Date(value.v);
      case 'r': return new RegExp(value.v, value.f);
      case 'b': return decode64(value.v).buffer;
      case 't': {
        const bytes = decode64(value.v), kind = globalThis[value.n];
        if (value.n === 'DataView') return new DataView(bytes.buffer);
        return new kind(bytes.buffer, 0, bytes.byteLength / kind.BYTES_PER_ELEMENT);
      }
      case 'B': {
        const bytes = decode64(value.v);
        return value.n === null ? new Blob([bytes], {type: value.t})
          : new File([bytes], value.n, {type: value.t, lastModified: value.m ?? 0});
      }
      case 'm': return new Map(value.v.map(([key, item]) => [decode(key), decode(item)]));
      case 's': return new Set(value.v.map(decode));
      case 'o': return Object.fromEntries(Object.entries(value.v).map(([key, item]) => [key, decode(item)]));
    }
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, decode(item)]));
  };

  const asked = request => new Promise((done, failed) => {
    request.onsuccess = () => done(request.result);
    request.onerror = () => failed(request.error);
    request.onblocked = () => failed(new Error('blocked'));
  });
  const ended = transaction => new Promise((done, failed) => {
    transaction.oncomplete = () => done();
    transaction.onerror = transaction.onabort = () => failed(transaction.error || new Error('aborted'));
  });

  const readBase = async (name, room) => {
    const base = await asked(indexedDB.open(name));
    let skipped = 0;
    try {
      const names = Array.from(base.objectStoreNames), stores = [];
      if (!names.length) return {name, version: base.version, stores, skipped};
      const reading = base.transaction(names, 'readonly');
      const pending = names.map(storeName => {
        const store = reading.objectStore(storeName);
        // An index can be asked for only while the transaction lives.
        const indexes = Array.from(store.indexNames).map(indexName => {
          const index = store.index(indexName);
          return {name: index.name, keyPath: index.keyPath, unique: index.unique, multiEntry: index.multiEntry};
        });
        return {store, indexes, keys: asked(store.getAllKeys()), values: asked(store.getAll())};
      });
      await ended(reading);
      for (const {store, indexes, keys, values} of pending) {
        const allKeys = await keys, allValues = await values, rows = [];
        for (let at = 0; at < allKeys.length; at++) {
          try {
            rows.push([await encode(allKeys[at], []), await encode(allValues[at], [])]);
            room.left -= JSON.stringify(rows[rows.length - 1]).length;
            if (room.left < 0) throw new RangeError('too big');
          } catch (error) {
            if (error instanceof RangeError) throw error;
            room.skipped += 1;
            skipped += 1;
          }
        }
        stores.push({name: store.name, keyPath: store.keyPath, autoIncrement: store.autoIncrement, indexes, rows});
      }
      // A base with a record that can't cross (MSAL's or Proton's CryptoKey)
      // goes as nothing: written without it, the sign-in it holds is broken.
      return skipped ? {name, version: base.version, stores: [], skipped} : {name, version: base.version, stores, skipped};
    } finally { base.close(); }
  };

  const read = async limit => {
    const local = [];
    for (let at = 0; at < localStorage.length; at++) {
      const key = localStorage.key(at);
      local.push([key, localStorage.getItem(key)]);
    }
    const room = {left: limit, skipped: 0};
    room.left -= JSON.stringify(local).length;
    let bases = [], whole = true;
    try {
      // getAll holds a whole store at once: a site with gigabytes in there
      // (mail kept offline, a chat's media) is not read to find that out.
      const used = navigator.storage && navigator.storage.estimate ? (await navigator.storage.estimate()).usage : 0;
      if (used > limit * 4) throw new RangeError('too big');
      for (const {name} of await indexedDB.databases()) {
        if (name !== undefined && name !== null) bases.push(await readBase(name, room));
      }
    } catch (error) {
      // Too big, or a base that won't open: the bases there stay as they are.
      bases = [];
      whole = false;
    }
    return {local, bases, whole, skipped: room.skipped};
  };

  const writeBase = async ({name, version, stores}) => {
    await asked(indexedDB.deleteDatabase(name));
    const opening = indexedDB.open(name, version);
    opening.onupgradeneeded = () => {
      for (const {name: storeName, keyPath, autoIncrement, indexes} of stores) {
        const store = opening.result.createObjectStore(storeName, {keyPath: keyPath ?? undefined, autoIncrement});
        for (const index of indexes) store.createIndex(index.name, index.keyPath, {unique: index.unique, multiEntry: index.multiEntry});
      }
    };
    const base = await asked(opening);
    try {
      const names = Array.from(base.objectStoreNames);
      if (!names.length) return;
      const writing = base.transaction(names, 'readwrite');
      for (const {name: storeName, keyPath, rows} of stores) {
        const store = writing.objectStore(storeName);
        for (const [key, value] of rows) {
          if (keyPath === null) store.put(decode(value), decode(key));
          else store.put(decode(value));
        }
      }
      await ended(writing);
    } finally { base.close(); }
  };

  const write = async ({local, bases, whole}) => {
    localStorage.clear();
    let refused = 0;
    for (const [key, value] of local) {
      try { localStorage.setItem(key, value); } catch { refused += 1; }
    }
    if (whole) {
      for (const {name} of await indexedDB.databases()) {
        if (name && !bases.some(base => base.name === name)) await asked(indexedDB.deleteDatabase(name));
      }
      // One that couldn't cross whole stays as the destination has it.
      for (const base of bases) if (!base.skipped) await writeBase(base);
    }
    return refused;
  };

  switch (call.op) {
    case 'read': {
      const found = await read(call.limit);
      carry.text = JSON.stringify(found);
      return {length: carry.text.length, keys: found.local.length, bases: found.bases.length, whole: found.whole, skipped: found.skipped};
    }
    case 'slice': {
      let end = Math.min(call.at + call.size, carry.text.length);
      // Never between the two halves of a pair: each part crosses as text.
      const last = carry.text.charCodeAt(end - 1);
      if (end < carry.text.length && last >= 0xD800 && last <= 0xDBFF) end -= 1;
      return {part: carry.text.slice(call.at, end), next: end};
    }
    case 'begin':
      carry.text = '';
      return {};
    case 'add':
      carry.text += call.part;
      return {};
    case 'write': {
      const refused = await write(JSON.parse(carry.text));
      carry.text = '';
      return {refused};
    }
  }
  throw new Error('unknown step');
})
