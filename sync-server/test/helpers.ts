import { SELF } from "cloudflare:test";

const BASE = "https://sync.test";
let counter = 0;

export function newAccount(): string {
  counter += 1;
  return `acct${counter.toString().padStart(4, "0")}_${crypto.randomUUID().replace(/-/g, "")}`.slice(0, 40);
}

export function call(path: string, init: Omit<RequestInit, "body"> & { token?: string; body?: any } = {}) {
  const headers = new Headers(init.headers);
  if (init.token) headers.set("authorization", `Bearer ${init.token}`);
  let body = init.body;
  if (body !== undefined && typeof body !== "string") {
    body = JSON.stringify(body);
    headers.set("content-type", "application/json");
  }
  return SELF.fetch(BASE + path, { ...init, headers, body });
}

export async function register(account: string, device = "mac1", secret = "s3cret"): Promise<string> {
  const res = await call(`/v1/accounts/${account}/devices`, {
    method: "POST",
    body: { secret, device: { id: device, name: `Mac ${device}`, model: "Mac15,3" } },
  });
  if (res.status !== 200) throw new Error(`register ${res.status} ${await res.text()}`);
  return ((await res.json()) as { token: string }).token;
}

export function blob(text: string): string {
  return btoa(text);
}

export class Client {
  private queue: any[] = [];
  private waiters: ((m: any) => void)[] = [];
  closed: Promise<{ code: number }>;

  constructor(readonly ws: WebSocket) {
    ws.accept();
    ws.addEventListener("message", (e) => {
      const msg = JSON.parse(e.data as string);
      const waiter = this.waiters.shift();
      if (waiter) waiter(msg);
      else this.queue.push(msg);
    });
    this.closed = new Promise((resolve) => ws.addEventListener("close", (e) => resolve({ code: e.code })));
  }

  send(msg: unknown) {
    this.ws.send(JSON.stringify(msg));
  }

  next(timeout = 2000): Promise<any> {
    if (this.queue.length) return Promise.resolve(this.queue.shift());
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("no message")), timeout);
      this.waiters.push((m) => {
        clearTimeout(timer);
        resolve(m);
      });
    });
  }

  // Resolves to null when nothing arrives within the window.
  async quiet(window = 200): Promise<any> {
    try {
      return await this.next(window);
    } catch {
      return null;
    }
  }

  async hello(cursor = 0) {
    this.send({ t: "hello", cursor, v: 1 });
    return this.next();
  }

  async push(id: string, changes: { name: string; base: number; blob: string }[], alert?: string, alertID?: string, withdraw = false) {
    this.send({ t: "push", id, changes, ...(alert ? { alert } : {}), ...(alertID ? { alertID } : {}), ...(withdraw ? { withdraw } : {}) });
    return this.next();
  }
}

export async function upgrade(account: string, token?: string): Promise<Response> {
  return call(`/v1/accounts/${account}/socket`, { token, headers: { upgrade: "websocket" } });
}

export async function connect(account: string, token: string): Promise<Client> {
  const res = await upgrade(account, token);
  if (res.status !== 101 || !res.webSocket) throw new Error(`upgrade ${res.status}`);
  return new Client(res.webSocket);
}
